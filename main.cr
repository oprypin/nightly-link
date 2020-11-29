require "http"
require "ecr"

require "cache"
require "halite"
require "athena"
require "sqlite3"

require "./string_util"
require "./github_api"

GITHUB_APP_NAME      = ENV["GITHUB_APP_NAME"]
GITHUB_APP_ID        = ENV["GITHUB_APP_ID"].to_i
GITHUB_CLIENT_ID     = ENV["GITHUB_CLIENT_ID"]
GITHUB_CLIENT_SECRET = ENV["GITHUB_CLIENT_SECRET"]
GITHUB_PEM_FILENAME  = ENV["GITHUB_PEM_FILENAME"]
APP_SECRET           = ENV["APP_SECRET"]
FALLBACK_INSTALL_ID  = ENV["FALLBACK_INSTALLATION_ID"].to_i64
PORT                 = ENV["PORT"].to_i

D = DB.open("sqlite3:./db.sqlite")
D.exec(%(
  CREATE TABLE IF NOT EXISTS installations (
    repo_owner TEXT NOT NULL, installation_id INTEGER NOT NULL, public_repos TEXT NOT NULL, private_repos TEXT NOT NULL,
    UNIQUE(repo_owner)
  )
))

record RepoInstallation,
  repo_owner : String,
  installation_id : InstallationId,
  public_repos : DelimitedString,
  private_repos : DelimitedString do
  def write : Nil
    D.exec(%(
      REPLACE INTO installations (repo_owner, installation_id, public_repos, private_repos) VALUES(?, ?, ?, ?)
    ), @repo_owner, @installation_id, @public_repos.to_s, @private_repos.to_s)
  end

  def self.read(*, repo_owner : String) : RepoInstallation?
    D.query(%(
      SELECT installation_id, public_repos, private_repos FROM installations WHERE repo_owner = ? LIMIT 1
    ), repo_owner) do |rs|
      rs.each do
        return new(
          repo_owner, rs.read(InstallationId),
          DelimitedString.new(rs.read(String)), DelimitedString.new(rs.read(String))
        )
      end
    end
  end

  def self.delete(repo_owner : String) : Nil
    D.exec(%(
      DELETE FROM installations WHERE repo_owner = ?
    ), repo_owner)
  end

  def self.refresh(installation : Installation, token = nil) : RepoInstallation
    public_repos = DelimitedString::Builder.new
    private_repos = DelimitedString::Builder.new
    Repositories.for_installation(installation.id, token: token) do |repo|
      if (repo_name = repo.full_name.lchop?("#{installation.account.login}/"))
        (repo.private? ? private_repos : public_repos) << repo_name
      end
    end
    inst = RepoInstallation.new(
      installation.account.login, installation.id,
      public_repos.build, private_repos.build
    )
    inst.write
    inst
  end

  def password(repo_name : String) : String
    hash = OpenSSL::Digest.new("SHA256")
    hash.update("#{installation_id}\n#{repo_owner}\n#{repo_name}\n#{APP_SECRET}")
    hash.final.hexstring[...40]
  end

  def verify(*, repo_name : String, h : String?) : String?
    result = nil
    unless public_repos.includes?(repo_name) ||
           h && private_repos.includes?(repo_name) && h == (result = password(repo_name))
      raise ART::Exceptions::NotFound.new("Not found: #{repo_owner}/#{repo_name}")
    end
    result
  end

  def self.verified_token(repo_owner : String, repo_name : String, *, h : String?) : {InstallationToken, String?}
    if (inst = RepoInstallation.read(repo_owner: repo_owner))
      h = inst.verify(repo_name: repo_name, h: h)
      {AppClient.token(inst.installation_id), h}
    else
      {AppClient.token(FALLBACK_INSTALL_ID), nil}
    end
  end
end

HTML_HEADERS = HTTP::Headers{"content-type" => MIME.from_extension(".html")}

class DashboardController < ART::Controller
  RECONFIGURE_URL = "https://github.com/apps/#{GITHUB_APP_NAME}/installations/new"
  AUTH_URL        = "https://github.com/login/oauth/authorize?" + HTTP::Params.encode({
    client_id: GITHUB_CLIENT_ID, scope: "",
  })

  WORKFLOW_EXAMPLES = [
    "https://github.com/actions/upload-artifact/blob/main/.github/workflows/test.yml",
    "https://github.com/crystal-lang/crystal/blob/master/.github/workflows/win.yml",
    "https://github.com/quassel/quassel/blob/master/.github/workflows/main.yml",
  ]

  def workflow_pattern(repo : String? = nil) : Regex
    return %r(^https?://github.com/(#{repo})/(blob|tree|raw|blame|commits)/([^/]+)/\.github/workflows/([^/]+)\.ya?ml$) if repo
    return %r(^https?://github.com/([^/]+/[^/]+)/(blob|tree|raw|blame|commits)/([^/]+)/\.github/workflows/([^/]+)\.ya?ml$)
  end

  def workflow_placeholder(repo = "$user/$repo") : String
    "https://github.com/#{repo}/blob/$branch/.github/workflows/$workflow.yml"
  end

  @[ART::Get("/")]
  def index : ART::Response
    messages = Tuple.new
    toplevel = true
    url = h = nil
    ART::Response.new(headers: HTML_HEADERS) do |io|
      io << "<title>nightly.link</title>"
      ECR.embed("head.html", io)
      ECR.embed("README.html", io)
    end
  end

  @[ART::Post("/")]
  def index(request : HTTP::Request) : ART::Response
    if (body = request.body)
      data = HTTP::Params.parse(body.gets_to_end)
      url = data["url"]?
      h = data["h"]?
    end

    messages = [] of String
    if url.presence
      if url =~ workflow_pattern
        repo, branch, workflow = $1, $3, $4
        if branch =~ /^[0-9a-fA-F]{32,}$/
          messages.unshift("Make sure you're on a branch (such as 'master'), not a commit (which '#{$0}' seems to be).")
        else
          link = "/#{repo}/workflows/#{workflow}/#{branch}"
          link += "?h=#{h}" if h
          return ART::RedirectResponse.new(link)
        end
      end
      messages.unshift("Did not detect a link to a GitHub workflow file.")
    end

    toplevel = true
    ART::Response.new(headers: HTML_HEADERS) do |io|
      io << "<title>nightly.link</title>"
      ECR.embed("head.html", io)
      ECR.embed("README.html", io)
    end
  end

  @[ART::QueryParam("code")]
  @[ART::Get("/dashboard")]
  def do_auth(code : String? = nil) : ART::Response
    if !code
      return ART::RedirectResponse.new(AUTH_URL)
    end

    resp = Client.post("https://github.com/login/oauth/access_token", form: {
      "client_id"     => GITHUB_CLIENT_ID,
      "client_secret" => GITHUB_CLIENT_SECRET,
      "code"          => code,
    }).tap(&.raise_for_status)
    resp = HTTP::Params.parse(resp.body)
    begin
      token = UserToken.new(resp["access_token"])
    rescue e
      if resp["error"]? == "bad_verification_code"
        return ART::RedirectResponse.new("/dashboard")
      end
      raise e
    end

    installations = [] of RepoInstallation

    Installations.for_user(token: token) do |iinst|
      installations << RepoInstallation.refresh(iinst, token)
    end

    return ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("dashboard.html", io)
    end
  end

  @[ART::QueryParam("installation_id")]
  @[ART::Get("/setup")]
  def do_setup(installation_id : InstallationId) : ART::Response
    inst = Installation.for_id(installation_id, AppClient.jwt)
    RepoInstallation.refresh(inst)
    ART::RedirectResponse.new("/")
  end

  record Link, url : String, title : String

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/workflows/:workflow/:branch")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, h : String?) : ART::Response
    token, h = RepoInstallation.verified_token(repo_owner, repo_name, h: h)
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    links = [] of Link
    begin
      WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token, max_items: 1) do |run|
        Artifacts.for_run(repo_owner, repo_name, run.id, token) do |art|
          links << Link.new("/#{repo_owner}/#{repo_name}/workflows/#{workflow.rchop(".yml")}/#{branch}/#{art.name}#{"?h=#{h}" if h}", art.name)
        end
      end
    rescue e : Halite::Exception::ClientError
      if e.status_code.in?(401, 404)
        raise ART::Exceptions::NotFound.new("No runs found for workflow '#{workflow}' and branch '#{branch}'")
      else
        raise e
      end
    end
    title = "Workflow #{workflow} | Branch #{branch}"
    return ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("artifact_list.html", io)
    end
  end
end

class ArtifactsController < ART::Controller
  record Link, url : String, title : String? = nil, ext : Bool = false, zip : Bool = false

  struct Result
    property links = Array(Link).new
    property title : {String, String} = {"", ""}
  end

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/workflows/:workflow/:branch/:artifact")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, artifact : String, h : String?) : ArtifactsController::Result
    token, h = RepoInstallation.verified_token(repo_owner, repo_name, h: h)
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    begin
      WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token, max_items: 1) do |run|
        result = by_run(repo_owner, repo_name, run.id, artifact, run.check_suite_url.rpartition("/").last.to_i64?, h)
        result.title = {"Repository #{repo_owner}/#{repo_name}", "Workflow #{workflow} | Branch #{branch} | Artifact #{artifact}"}
        result.links << Link.new("https://github.com/#{repo_owner}/#{repo_name}/actions?" + HTTP::Params.encode({
          query: "event:push is:success workflow:#{workflow} branch:#{branch}",
        }), "GitHub: browse runs for workflow '#{workflow}' on branch '#{branch}'", ext: true)
        result.links << Link.new(
          "/#{repo_owner}/#{repo_name}/workflows/#{workflow.rchop(".yml")}/#{branch}/#{artifact}#{"?h=#{h}" if h}",
          result.title[1], zip: true
        )
        return result
      end
    rescue e : Halite::Exception::ClientError
      if e.status_code.in?(401, 404)
        raise ART::Exceptions::NotFound.new("No runs found for workflow '#{workflow}' and branch '#{branch}'")
      else
        raise e
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for workflow '#{workflow}' and branch '#{branch}'")
  end

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/actions/runs/:run_id/:artifact")]
  def by_run(repo_owner : String, repo_name : String, run_id : Int64, artifact : String, check_suite_id : Int64?, h : String?) : ArtifactsController::Result
    token, h = RepoInstallation.verified_token(repo_owner, repo_name, h: h)
    Artifacts.for_run(repo_owner, repo_name, run_id, token) do |art|
      if art.name == artifact
        result = by_artifact(repo_owner, repo_name, art.id, check_suite_id, h)
        result.title = {"Repository #{repo_owner}/#{repo_name}", "Run ##{run_id} | Artifact #{artifact}"}
        result.links << Link.new(
          "https://github.com/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}",
          "GitHub: view run ##{run_id}", ext: true
        )
        result.links << Link.new(
          "/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/#{artifact}#{"?h=#{h}" if h}",
          result.title[1], zip: true
        )
        return result
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for run ##{run_id}")
  end

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/actions/artifacts/:artifact_id")]
  def by_artifact(repo_owner : String, repo_name : String, artifact_id : Int64, check_suite_id : Int64?, h : String?) : ArtifactsController::Result
    token, h = RepoInstallation.verified_token(repo_owner, repo_name, h: h)
    tmp_link = Artifact.zip_by_id(repo_owner, repo_name, artifact_id, token: token)
    result = Result.new
    result.title = {"Repository #{repo_owner}/#{repo_name}", "Artifact ##{artifact_id}"}
    result.links << Link.new(tmp_link, "Ephemeral direct download link (expires in <1 minute)")
    result.links << Link.new(
      "https://github.com/#{repo_owner}/#{repo_name}/suites/#{check_suite_id}/artifacts/#{artifact_id}",
      "GitHub: direct download of artifact ##{artifact_id} (requires GitHub login)", ext: true
    ) if check_suite_id
    result.links << Link.new(
      "/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}#{"?h=#{h}" if h}",
      result.title[1], zip: true
    )
    return result
  end

  @[ADI::Register]
  class ResultListener
    include AED::EventListenerInterface

    def initialize
      @zip = false
    end

    def self.subscribed_events : AED::SubscribedEvents
      AED::SubscribedEvents{ART::Events::View => 100, ART::Events::Request => 100, ART::Events::Response => 100}
    end

    def call(event : ART::Events::Request, dispatcher : AED::EventDispatcherInterface) : Nil
      if (path = event.request.path.rchop?(".zip"))
        event.request.path = path
        @zip = true
      end
    end

    def call(event : ART::Events::View, dispatcher : AED::EventDispatcherInterface) : Nil
      if (result = event.action_result.as?(Result))
        if @zip
          event.response = ART::RedirectResponse.new(result.links.first.url)
          @zip = false
        else
          title = result.title
          links = result.links.reverse!
          event.response = ART::Response.new(headers: HTML_HEADERS) do |io|
            ECR.embed("head.html", io)
            ECR.embed("artifact.html", io)
          end
        end
      end
    end

    def call(event : ART::Events::Response, dispatcher : AED::EventDispatcherInterface) : Nil
      if @zip
        raise ART::Exceptions::NotFound.new("")
      end
    end
  end
end

ART.run(host: "127.0.0.1", port: PORT)
