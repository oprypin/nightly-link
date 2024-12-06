ENV["GITHUB_APP_NAME"] = "github_app_name"
ENV["GITHUB_APP_ID"] = "12345"
ENV["GITHUB_CLIENT_ID"] = "github_client_id"
ENV["GITHUB_CLIENT_SECRET"] = "1" * 40
ENV["APP_SECRET"] = "1" * 32
ENV["FALLBACK_INSTALLATION_ID"] = INSTALLATION_F.to_s

INSTALLATION_F = 4433221_i64
INSTALLATION_1 = 7654321_i64
WORKFLOW_1     =      654321
CHECK_SUITE_1  =  1987654321
RUN_1          =   987654321
RUN_2          =   987654324
RUN_3          =   987654326
JOB_1          =  9977553311
JOB_2          =  9977553317
ARTIFACT_1     =    87654321
ARTIFACT_2     =    87654325
PRIVATE_REPO   = "oprypin/test-private-repo"

require "http"
require "spec_assert"
require "webmock"
require "../src/nightly_link"

macro assert_canonical(url)
  assert resp.status == HTTP::Status::OK
  assert resp.headers["Content-Type"] == "text/html"
  assert body.includes?(%(<link rel="canonical" href="#{HTML.escape({{url}})}">))
end

macro assert_redirect(url)
  assert resp.status == HTTP::Status::FOUND
  assert resp.headers["Location"] == {{url}}
end

macro assert_contents(links)
  %offset = 0
  %links = ({{links}}).map do |s|
    body.index(s, %offset).tap do |r|
      %offset = r + 1 if r
    end
  end
  assert %links.compact == %links
end

macro assert_nofollow
  assert body.partition("<title>").last !~ /(?<!rel="nofollow" )href=https:\/\/nightly.link\//
end

Spec.before_each do
  WebMock.reset
  WebMock.stub(:post, "https://api.github.com/app/installations/#{INSTALLATION_F}/access_tokens").to_return(
    body: %({"token": "v1.1f699f1069f60xxx"}))
  WebMock.stub(:post, "https://api.github.com/app/installations/#{INSTALLATION_1}/access_tokens").to_return(
    body: %({"token": "v1.1f69921069f60zzz"}))
end

describe "index" do
  before_each do
    WebMock.stub(:get, %r(https://api.github.com/repos/.+/runs\?)).to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, %r(https://api.github.com/repos/.+/runs/.+/artifacts\?)).to_return(
      body: %({"artifacts":[{"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"}]}))
  end

  test do
    resp, body = serve("/")
    assert_canonical "https://nightly.link/"
    assert_contents [
      "select your repositories",
      "/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}",
      "/actions/runs/#{RUN_1}",
    ]
    assert_nofollow
  end

  describe "redirect" do
    {query: "/?url=https://github.com", bare: ""}.each do |kind, prefix|
      describe kind do
        test "workflow" do
          resp, body = serve("#{prefix}/oprypin/nightly.link/blob/master/.github/workflows/upload-test.yml")
          assert_redirect "/oprypin/nightly.link/workflows/upload-test/master?preview"
        end

        test "artifact_download" do
          resp, body = serve("#{prefix}/oprypin/nightly.link/suites/1987122430/artifacts/39579703")
          assert_redirect "/oprypin/nightly.link/actions/artifacts/39579703#{".zip" if kind == :bare}"
        end

        test "logs_download" do
          resp, body = serve("#{prefix}/oprypin/nightly.link/commit/30c72d4e1100a04a9ee657083de0bd2b8f706eb7/checks/1849327325/logs")
          assert_redirect "/oprypin/nightly.link/runs/1849327325#{".txt" if kind == :bare}"
        end
      end
    end

    test "run" do
      resp, body = serve("/?url=" + URI.encode_www_form("https://github.com/oprypin/nightly.link/actions/runs/545511762"))
      assert_redirect "/oprypin/nightly.link/actions/runs/545511762"
    end

    test "job" do
      resp, body = serve("/?url=" + URI.encode_www_form("https://github.com/oprypin/nightly.link/runs/1849327325?check_suite_focus=true"))
      assert_redirect "/oprypin/nightly.link/runs/1849327325"
    end

    test "unicode url" do
      resp, body = serve("/?url=" + URI.encode_www_form("https://github.com/oprypin/nightly.link/blob/%D1%82%D0%B5%D1%81%D1%82/.github/workflows/build.yml"))
      assert_redirect "/oprypin/nightly.link/workflows/build/%D1%82%D0%B5%D1%81%D1%82?preview"
    end

    test "private" do
      url = URI.encode_www_form("https://github.com/#{PRIVATE_REPO}/blob/SomeBranch/.github/workflows/SomeWorkflow.yml")
      resp, body = serve("/?url=#{url}&h=6c9bf24563d1896f5de321ce6043413f8c75ef16")
      assert_redirect "/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch?preview&h=6c9bf24563d1896f5de321ce6043413f8c75ef16"
    end

    test "bad url" do
      resp, body = serve("/?url=https://hmm")
      assert resp.status == HTTP::Status::OK
      assert_contents [
        "select your repositories", "not detect a link",
      ]
      assert_nofollow
    end
  end
end

describe "dashboard" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/user/installations?per_page=10").to_return(
      body: %({"installations":[
                {"id":#{INSTALLATION_1},"account":{"login":"oprypin"},"updated_at":"2020-12-15T01:00:00Z"}]}))
    WebMock.stub(:get, "https://api.github.com/user/installations/#{INSTALLATION_1}/repositories?per_page=300").to_return(
      body: %({"repositories":[
                {"full_name":"oprypin/nightly.link","private":false,"fork":true},
                {"full_name":"oprypin/test-private-repo","private":true,"fork":false}]}))
  end

  test "redirect" do
    resp, body = serve("/dashboard")
    assert_redirect "https://github.com/login/oauth/authorize?client_id=github_client_id&scope=&redirect_uri=https%3A%2F%2Fnightly.link%2Fdashboard"
  end

  test "with code" do
    WebMock.stub(:post, "https://github.com/login/oauth/access_token").to_return(
      body: "access_token=tokentokentoken")
    resp, body = serve("/dashboard?code=codecodecode")
    assert resp.status == HTTP::Status::OK
  end

  test "redirect with bad code" do
    WebMock.stub(:post, "https://github.com/login/oauth/access_token").to_return(
      body: "error=bad_verification_code")
    resp, body = serve("/dashboard?code=codecodecode")
    assert_redirect "/dashboard"
  end
end

describe "dash_by_branch" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{RUN_2}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[
                {"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"},
                {"id":#{ARTIFACT_2},"name":"AnotherArtifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_2}"}]}))
  end

  test do
    resp, body = serve("/uSerName/RepoName/workflows/SomeWorkflow/SomeBranch")
    assert_canonical "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch"
    assert_contents [
      "Repository UserName/RepoName", "Workflow SomeWorkflow.yml | Branch SomeBranch",
      "Repository UserName/RepoName", "Workflow SomeWorkflow.yml | Branch SomeBranch",
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact",
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip",
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip",
    ]
    assert_nofollow
  end

  test "bad request" do
    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch?status=foo")
    assert resp.status == HTTP::Status::BAD_REQUEST
  end

  describe "private" do
    test "without password" do
      resp, body = serve("/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch")
      assert resp.status == HTTP::Status::NOT_FOUND
      assert_contents [
        "Repository not found:", "https://github.com/#{PRIVATE_REPO}",
      ]
      assert_nofollow
    end

    test "with wrong password" do
      resp, body = serve("/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch?h=4007f0bdefca32af97b5abbe49644bd3155fe6aa")
      assert resp.status == HTTP::Status::NOT_FOUND
      assert_contents [
        "Repository not found:", "https://github.com/#{PRIVATE_REPO}",
      ]
      assert_nofollow
    end

    test do
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
        body: %({"workflow_runs":[
                  {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/#{PRIVATE_REPO}/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"#{PRIVATE_REPO}","private":false,"fork":false}}]}))
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
        body: %({"workflow_runs":[
                  {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/#{PRIVATE_REPO}/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"#{PRIVATE_REPO}","private":false,"fork":false}}]}))
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/runs/#{RUN_2}/artifacts?per_page=100").to_return(
        body: %({"artifacts":[
                  {"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/#{PRIVATE_REPO}/actions/artifacts/#{ARTIFACT_1}"},
                  {"id":#{ARTIFACT_2},"name":"AnotherArtifact","url":"https://api.github.com/repos/#{PRIVATE_REPO}/actions/artifacts/#{ARTIFACT_2}"}]}))

      resp, body = serve("/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch?h=6c9bf24563d1896f5de321ce6043413f8c75ef16")
      assert_canonical "https://nightly.link/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch?h=6c9bf24563d1896f5de321ce6043413f8c75ef16"
      assert_contents [
        "Repository #{PRIVATE_REPO}", "Workflow SomeWorkflow.yml | Branch SomeBranch",
        "Repository #{PRIVATE_REPO}", "Workflow SomeWorkflow.yml | Branch SomeBranch",
        "https://nightly.link/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact?h=6c9bf24563d1896f5de321ce6043413f8c75ef16",
        "https://nightly.link/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip?h=6c9bf24563d1896f5de321ce6043413f8c75ef16",
      ]
      assert_nofollow
    end
  end

  test "with .yml" do
    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow.yml/SomeBranch")
    assert_canonical "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch"
  end

  test "with .yaml" do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yaml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yaml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))

    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow.yaml/SomeBranch")
    assert_canonical "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow.yaml/SomeBranch"
    assert_contents [
      "Repository UserName/RepoName", "Workflow SomeWorkflow.yaml | Branch SomeBranch",
      "Repository UserName/RepoName", "Workflow SomeWorkflow.yaml | Branch SomeBranch",
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow.yaml/SomeBranch/Some%23Artifact",
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow.yaml/SomeBranch/Some%23Artifact.zip",
    ]
    assert_nofollow
  end
end

describe "dash_by_run" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{RUN_1}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[{"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"}]}))
  end

  test do
    resp, body = serve("/uSerName/RepoName/actions/runs/#{RUN_1}")
    assert_canonical "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_1}"
    assert_contents [
      "Repository UserName/RepoName", "Run ##{RUN_1}",
      "Repository UserName/RepoName", "Run ##{RUN_1}",
      "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact",
      "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact.zip",
      "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact.zip",
    ]
    assert_nofollow
  end

  test "no artifacts" do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{RUN_3}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[]}))

    resp, body = serve("/UserName/RepoName/actions/runs/#{RUN_3}")
    assert resp.status == HTTP::Status::NOT_FOUND
    assert_contents [
      "No artifacts found for run ##{RUN_3}",
      "https://github.com/UserName/RepoName/actions/runs/#{RUN_3}#artifacts",
    ]
    assert_nofollow
  end
end

describe "by_branch" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{RUN_2}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[
                {"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"},
                {"id":#{ARTIFACT_2},"name":"AnotherArtifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_2}"}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test do
    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact")
    assert_canonical "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact"
    assert_contents [
      "Repository UserName/RepoName", "Workflow SomeWorkflow.yml | Branch SomeBranch | Artifact Some#Artifact",
    ] * 2 + [
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip",
      "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_2}/Some%23Artifact.zip",
      "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip",
    ].flat_map { |s| [s, s] } + [
      "http://example.org/download1",
      "https://github.com/UserName/RepoName/actions?query=event%3Aschedule+is%3Asuccess+branch%3ASomeBranch",
      "https://github.com/UserName/RepoName/actions/runs/#{RUN_2}#artifacts",
      "https://github.com/UserName/RepoName/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}",
    ]
    assert_nofollow
  end

  test "completed" do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=completed").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=completed").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))

    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact?status=completed")
    assert_canonical "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact"
  end

  test "failure" do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=failure").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=failure").to_return(
      body: %({"workflow_runs":[
                {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))

    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact?status=failure")
    assert_canonical "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact"
  end

  test "redirect" do
    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip")
    assert_redirect "http://example.org/download1"
  end

  describe "private" do
    test "without password" do
      resp, body = serve("/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip")
      assert resp.status == HTTP::Status::NOT_FOUND
      assert_contents [
        "Repository not found:", "https://github.com/#{PRIVATE_REPO}",
      ]
      assert_nofollow
    end

    test "with wrong password" do
      resp, body = serve("/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip?h=4007f0bdefca32af97b5abbe49644bd3155fe6aa")
      assert resp.status == HTTP::Status::NOT_FOUND
      assert_contents [
        "Repository not found:", "https://github.com/#{PRIVATE_REPO}",
      ]
      assert_nofollow
    end

    test do
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
        body: %({"workflow_runs":[
                  {"id":#{RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/#{PRIVATE_REPO}/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"#{PRIVATE_REPO}","private":false,"fork":false}}]}))
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
        body: %({"workflow_runs":[
                  {"id":#{RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/#{PRIVATE_REPO}/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"#{PRIVATE_REPO}","private":false,"fork":false}}]}))
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/runs/#{RUN_2}/artifacts?per_page=100").to_return(
        body: %({"artifacts":[
                  {"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/#{PRIVATE_REPO}/actions/artifacts/#{ARTIFACT_1}"},
                  {"id":#{ARTIFACT_2},"name":"AnotherArtifact","url":"https://api.github.com/repos/#{PRIVATE_REPO}/actions/artifacts/#{ARTIFACT_2}"}]}))
      WebMock.stub(:get, "https://api.github.com/repos/#{PRIVATE_REPO}/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
        headers: HTTP::Headers{"location" => "http://example.org/download2"})

      resp, body = serve("/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact?h=6c9bf24563d1896f5de321ce6043413f8c75ef16")
      assert_canonical "https://nightly.link/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact?h=6c9bf24563d1896f5de321ce6043413f8c75ef16"
      assert_contents [
        "https://nightly.link/#{PRIVATE_REPO}/workflows/SomeWorkflow/SomeBranch/Some%23Artifact.zip?h=6c9bf24563d1896f5de321ce6043413f8c75ef16",
        "https://nightly.link/#{PRIVATE_REPO}/actions/runs/#{RUN_2}/Some%23Artifact.zip?h=6c9bf24563d1896f5de321ce6043413f8c75ef16",
        "https://nightly.link/#{PRIVATE_REPO}/actions/artifacts/#{ARTIFACT_1}.zip?h=6c9bf24563d1896f5de321ce6043413f8c75ef16",
      ].flat_map { |s| [s, s] } + [
        "http://example.org/download2",
        "https://github.com/#{PRIVATE_REPO}/actions?query=event%3Aschedule+is%3Asuccess+branch%3ASomeBranch",
        "https://github.com/#{PRIVATE_REPO}/actions/runs/#{RUN_2}#artifacts",
        "https://github.com/#{PRIVATE_REPO}/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}",
      ]
      assert_nofollow
    end
  end
end

describe "by_run" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{RUN_1}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[{"id":#{ARTIFACT_1},"name":"Some#Artifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test do
    resp, body = serve("/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact")
    assert_canonical "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact"
    assert_contents [
      "Repository UserName/RepoName", "Run ##{RUN_1} | Artifact Some#Artifact",
    ] * 2 + [
      "https://nightly.link/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact.zip",
      "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip",
    ].flat_map { |s| [s, s] } + [
      "http://example.org/download1",
      "https://github.com/UserName/RepoName/actions/runs/#{RUN_1}#artifacts",
    ]
    assert_nofollow
  end

  test "redirect" do
    resp, body = serve("/UserName/RepoName/actions/runs/#{RUN_1}/Some%23Artifact.zip")
    assert_redirect "http://example.org/download1"
  end
end

describe "by_artifact" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test do
    resp, body = serve("/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}")
    assert_canonical "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"
    assert_contents [
      "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip",
      "http://example.org/download1",
    ]
    assert_nofollow
  end

  test "redirect" do
    resp, body = serve("/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip")
    assert_redirect "http://example.org/download1"
  end

  test "no double zip" do
    resp, body = serve("/UserName/RepoName/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}.zip")
    assert resp.status == HTTP::Status::NOT_FOUND

    resp, body = serve("/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip.zip")
    assert resp.status == HTTP::Status::NOT_FOUND
  end
end

describe "by_job" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/jobs/#{JOB_1}/logs").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test do
    resp, body = serve("/uSerName/RepoName/runs/#{JOB_1}")
    assert_canonical "https://nightly.link/uSerName/RepoName/runs/#{JOB_1}"
    assert_contents [
      "Repository uSerName/RepoName", "Job ##{JOB_1}",
      "Repository uSerName/RepoName", "Job ##{JOB_1}",
      "https://nightly.link/uSerName/RepoName/runs/#{JOB_1}.txt",
      "http://example.org/download1",
      "https://github.com/uSerName/RepoName/runs/#{JOB_1}",
    ]
    assert_nofollow
  end

  test "txt" do
    resp, body = serve("/UserName/RepoName/runs/#{JOB_1}.txt")
    assert_redirect "http://example.org/download1"
  end

  describe "expired" do
    {"", ".txt"}.each do |kind|
      test kind do
        WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/jobs/#{JOB_2}/logs").to_return(
          status: 410)

        resp, body = serve("/UserName/RepoName/runs/#{JOB_2}#{kind}")
        assert resp.status == HTTP::Status::NOT_FOUND
        assert_contents [
          "expired", "https://github.com/UserName/RepoName/runs/#{JOB_2}",
        ]
        assert_nofollow
      end
    end
  end
end

describe "static" do
  test "logo" do
    ["/logo.svg", NightlyLink.gen_logo].each do |path|
      resp, body = serve(path)
      assert resp.status == HTTP::Status::OK
      assert resp.headers["Content-Type"] == "image/svg+xml"
    end
  end
end

D   = DB.open("sqlite3::memory:")
APP = NightlyLink.new(db: D)

RepoInstallation.new(
  repo_owner: PRIVATE_REPO.partition("/").first, installation_id: INSTALLATION_1,
  public_repos: DelimitedString.new("nightly.link\n"),
  private_repos: DelimitedString.new("#{PRIVATE_REPO.partition("/").last}\n")
).write(D)

def serve(method : String, path : String)
  io = IO::Memory.new
  yield request = HTTP::Request.new(method, path)
  response = HTTP::Server::Response.new(io)
  ctx = HTTP::Server::Context.new(request, response)
  APP.serve_request(ctx, reraise: true)
  Fiber.yield
  response.flush
  {response, io.to_s}
end

def serve(method : String, path : String)
  serve(method, path) { }
end

def serve(path : String)
  serve("GET", path) { }
end

def serve(path : String)
  serve("GET", path)
end
