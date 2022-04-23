module GenieSession

import SHA, HTTP, Dates, Logging, Random
import Genie


const PARAMS_SESSION_KEY    = :SESSION
const PARAMS_FLASH_KEY      = :FLASH

const SESSION_KEY_NAME = Ref{String}("__geniesid")

function session_key_name()
  SESSION_KEY_NAME[]
end

function session_key_name(name::String)
  SESSION_KEY_NAME[] = name
end


const SESSION_OPTIONS = Ref{Dict{String,Any}}(Dict{String,Any}("Path" => "/", "HttpOnly" => true, "Secure" => Genie.config.ssl_enabled))

function session_options()
  SESSION_OPTIONS[]
end

function session_options(options::Dict{String,Any})
  SESSION_OPTIONS[] = options
end


"""
    mutable struct Session

Represents a session object
"""
mutable struct Session
  id::String
  data::Dict{Symbol,Any}
end

Session(id::String) = Session(id, Dict{Symbol,Any}())

export Session, session

struct InvalidSessionIdException <: Exception
  msg::String
end
InvalidSessionIdException() =
  InvalidSessionIdException("Can't compute session id - make sure that secret_token!(token) is called in config/secrets.jl")


const CSPRNG = Random.RandomDevice()

include("Flash.jl")

"""
    id() :: String

Generates a new session id.
"""
function id() :: String
  if isempty(Genie.Secrets.secret_token())
    if !Genie.Configuration.isprod()
      @error "Empty Genie.Secrets.secret_token(); using a temporary token"
      Genie.Secrets.secret_token!()
    else
      throw(InvalidSessionIdException())
    end
  end

  bytes2hex(SHA.sha256(Genie.Secrets.secret_token() * string(rand(GenieSession.CSPRNG, UInt128))))
end


"""
    id(payload::Union{HTTP.Request,HTTP.Response}) :: String

Attempts to retrieve the session id from the provided `payload` object.
If that is not available, a new session id is created.
"""
function id(payload::Union{HTTP.Request,HTTP.Response}) :: String
  (Genie.Cookies.get(payload, session_key_name()) !== nothing) &&
    ! isempty(Genie.Cookies.get(payload, session_key_name())) &&
      return Genie.Cookies.get(payload, session_key_name())

  id()
end


"""
    id(req::HTTP.Request, res::HTTP.Response) :: String

Attempts to retrieve the session id from the provided request and response objects.
If that is not available, a new session id is created.
"""
function id(req::HTTP.Request, res::HTTP.Response) :: String
  for r in [req, res]
    val = Genie.Cookies.get(r, session_key_name())
    (val !== nothing) && ! isempty(val) &&
      return val
  end

  id()
end


"""
    init() :: Nothing

Sets up the session functionality, if configured.
"""
function __init__() :: Nothing
  GenieSession.start in Genie.Router.pre_match_hooks || push!(Genie.Router.pre_match_hooks, GenieSession.start)
  GenieSession.persist in Genie.Router.pre_response_hooks || push!(Genie.Router.pre_response_hooks, GenieSession.persist)

  nothing
end


"""
    start(session_id::String, req::HTTP.Request, res::HTTP.Response; options = Dict{String,String}()) :: Tuple{Session,HTTP.Response}

Initiates a new HTTP session with the provided `session_id`.

# Arguments
- `session_id::String`: the id of the session object
- `req::HTTP.Request`: the request object
- `res::HTTP.Response`: the response object
- `options::Dict{String,String}`: extra options for setting the session cookie, such as `Path` and `HttpOnly`
"""
function start(session_id::String, req::HTTP.Request, res::HTTP.Response;
                options::Dict{String,Any} = session_options()) :: Tuple{Session,HTTP.Response}
  Genie.Cookies.set!(res, session_key_name(), session_id, options)

  load(session_id), res
end


"""
    start(req::HTTP.Request, res::HTTP.Response; options::Dict{String,String} = Dict{String,String}()) :: Session

Initiates a new default session object, generating a new session id.

# Arguments
- `req::HTTP.Request`: the request object
- `res::HTTP.Response`: the response object
- `options::Dict{String,String}`: extra options for setting the session cookie, such as `Path` and `HttpOnly`
"""
function start(req::HTTP.Request, res::HTTP.Response, params::Dict{Symbol,Any} = Dict{Symbol,Any}(); options::Dict{String,Any} = session_options()) :: Tuple{HTTP.Request,HTTP.Response,Dict{Symbol,Any},Session}
  session, res = start(id(req, res), req, res; options = options)

  params[PARAMS_SESSION_KEY]   = session
  params[PARAMS_FLASH_KEY]     = begin
                                                if session !== nothing
                                                  s = get(session, PARAMS_FLASH_KEY)
                                                  if s === nothing
                                                    ""
                                                  else
                                                    unset!(session, PARAMS_FLASH_KEY)
                                                    s
                                                  end
                                                else
                                                  ""
                                                end
                                              end

  req, res, params, session
end
const start! = start


"""
    set!(s::Session, key::Symbol, value::Any) :: Session

Stores `value` as `key` on the `Session` object `s`.
"""
function set!(s::Session, key::Symbol, value::Any) :: Session
  s.data[key] = value
  persist(s)

  s
end
function set!(key::Symbol, value::Any) :: Session
  set!(session(), key, value)
end


"""
    get(s::Session, key::Symbol) :: Union{Nothing,Any}

Returns the value stored on the `Session` object `s` as `key`, wrapped in a `Union{Nothing,Any}`.
"""
function get(s::Session, key::Symbol) :: Union{Nothing,Any}
  haskey(s.data, key) ? (s.data[key]) : nothing
end
function get(key::Symbol) :: Union{Nothing,Any}
  get(session(), key)
end


"""
    get(s::Session, key::Symbol, default::T) :: T where T

Attempts to retrive the value stored on the `Session` object `s` as `key`.
If the value is not set, it returns the `default`.
"""
function get(s::Session, key::Symbol, default::T) where {T}
  val = get(s, key)

  val === nothing ? default : val
end
function get(key::Symbol, default::T) where {T}
  get(session(), key, default)
end
function get!(key::Symbol, default::T) where {T}
  get!(session(), key, default)
end
function get!(s::Session, key::Symbol, default::T) where {T}
  val = get(s, key, default)
  set!(key, val)

  val
end


"""
    unset!(s::Session, key::Symbol) :: Session

Removes the value stored on the `Session` `s` as `key`.
"""
function unset!(s::Session, key::Symbol) :: Session
  delete!(s.data, key)

  s
end


"""
    isset(s::Session, key::Symbol) :: Bool

Checks wheter or not `key` exists on the `Session` `s`.
"""
function isset(s::Union{Session,Nothing}, key::Symbol) :: Bool
  s !== nothing && haskey(s.data, key)
end


"""
    persist(s::Session) :: Session

Generic method for persisting session data - delegates to the underlying `SessionAdapter`.
"""
function persist end


"""
    load(session_id::String) :: Session

Loads session data from persistent storage - delegates to the underlying `SessionAdapter`.
"""
function load end


"""
    session(params::Dict{Symbol,Any}) :: Sessions.Session

Returns the `Session` object associated with the current HTTP request.
"""
function session(params::Dict{Symbol,Any} = Genie.Router.params()) :: Session
  ( (! haskey(params, PARAMS_SESSION_KEY) || isnothing(params[PARAMS_SESSION_KEY])) ) &&
    (params = GenieSession.start!(
      Base.get(params, Genie.Router.PARAMS_REQUEST_KEY, HTTP.Request()),
      Base.get(params, Genie.Router.PARAMS_RESPONSE_KEY, HTTP.Response())
    )[3])

  params[PARAMS_SESSION_KEY]
end

end
