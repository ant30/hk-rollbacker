require 'sinatra/base'
require 'haml'
require 'newrelic_rpm'
require 'httparty'
require 'json'
require 'digest'
require 'redis'
require 'time'
require './emails'
require './app/workers/monitoring'
require './lib/utils'
require './config/env'
require 'active_support/time'


# Expected environment
#  APPS = "app1;app2;app3"  # heroku app names
#  HTTP_USER = "user:SHA256passwordhashed"
#  API_KEY = "SHA256passwordhashed"
#  HEROKU_API_TOKEN = "echo {email}{API TOKEN} | base64"  # Token api from heroku with rollback available
#  REDIS_URI = "REDIS://:password@host:port"  # (localhost by default)
#  DEPLOY_TTL = 300  # seconds



$redis = Redis.new(:url => REDIS_URI)



def init_tests(app, email)
    now = Time.now.getutc
    data = {
      :app => app,
      :email => email,
      :timestamp => now.getutc.to_i,
      :date => now,
      :ok => 0,
      :errors => 0,
      :last_request => nil,
    }

    $redis.multi do
      $redis.mapped_hmset(redis_key(app), data)
    end
    MonitoringJob.perform_in(5.seconds, app, email)
end



class Heroku
  include HTTParty
  base_uri 'https://api.heroku.com'
  format :json
  headers 'Accept' => 'application/vnd.heroku+json; version=3'
  headers 'Authorization' => HEROKU_API_TOKEN
end
  

def heroku_rollback (app_name)

  releases = Heroku.get "/apps/#{app_name}/releases"

  previous_release = releases[-2]
  payload = {:release => previous_release["id"]}

  new_release = Heroku.post("/apps/#{app_name}/releases", :body => payload)
  
  {
    :previus_release => previous_release,
    :new_release => new_release,
  }
end


class Protected < Sinatra::Base
  def auth_basic?
    @auth ||= Rack::Auth::Basic::Request.new(request.env)
    stored_user, stored_password = HTTP_USER.split(':')
    unless @auth.provided? && @auth.basic? && @auth.credentials 
      return false
    end

    password_hash = Digest::SHA256.new() << @auth.credentials[1] 
    (@auth.credentials[0] == stored_user && password_hash = stored_password)
  end

  def auth_apikey?
    return false unless params[:key]
    password_hash = Digest::SHA256.new() << params[:key]
    password_hash == API_KEY
  end

  def is_newrelic?
    puts request.env["HTTP_X_NEWRELIC_ID"]
    puts request.env["HTTP_X_NEWRELIC_TRANSACTION"]
    (request.env.has_key?("HTTP_X_NEWRELIC_ID") && 
     request.env.has_key?("HTTP_X_NEWRELIC_TRANSACTION") &&
     request.env["HTTP_X_NEWRELIC_ID"] == NEWRELIC_API_ID)
  end

  def authorized?
    auth_basic? || auth_apikey? || is_newrelic?
  end


  before do
    $redis.set("started", Time.now.getutc)
    if not authorized?
      headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
      halt 401, "Not authorized\n"
    end
  end


  
  post '/:app/newrelease/' do
    app_name = params[:app]
    unless APPS.include?(app_name)
      response.status = 404
      return {:status => '404', :reason => 'Not found'}.to_json
    end

    payload = JSON.parse request.body.read

    unless payload.has_key?('email')
      response.status = 400
      return {:status => '400', :reason => 'email is required'}.to_json
    end

    now = Time.now.getutc
    data = {
      :app => app_name,
      :email => payload['email'],
      :timestamp => now.getutc.to_i,
      :date => now,
    }

    $redis.multi do
      $redis.mapped_hmset(redis_key(app_name), data)
      $redis.expire(redis_key(app_name), DEPLOY_TTL)
    end

    response.status = 201
    {:status => 'ok'}.to_json
  end

  post '/:app/rollback/' do
    app_name = params[:app]
    if request.env['CONTENT_TYPE'] == 'application/x-www-form-urlencoded'
        if params.has_key?("alert")
          payload = JSON.parse params["alert"]
        else
          response.status = 204
          return {
            :status=> '204',
            :reason => 'Only the alert message is implemented'
          }.to_json
        end
    else
      payload = JSON.parse request.body.read
    end

    unless APPS.include?(app_name)
      response.status = 404
      return {:status => '404', :reason => 'Not found'}.to_json
    end

    unless $redis.exists(redis_key(app_name))
      response.status = 202
      return {:status => '202', :reason => 'Last deploy is expired'}.to_json
    end

    unless newrelic_payload_validation(payload, app_name)
      response.status = 400
      return {
        :status=> '400',
        :reason => 'Invalid json content, required severity and account_name and message ending with down'
      }.to_json
    end

    email = $redis.hget(redis_key(app_name), 'email')
    $redis.del(redis_key(app_name))

    unless ROLLBACK_ENABLED
      send_email_rollback_request(app_name, email, payload)
      response.status = 201
      return {:status => '201', :reason => 'Rollback disabled, only this email is sent'}.to_json
    end

    begin
        result = heroku_rollback app_name if ROLLBACK_ENABLED
    rescue
      send_email_rollback_failed(app_name, email, payload) if EMAIL_ENABLED
      response.status = 500
      return {:status => '500', :reason => 'Rollback rejected by Heroku'}
    else
      if result[:new_release].code == 201
        response.status = 201

        if EMAIL_ENABLED
          send_email_rollback(app_name, email, payload)
        end
          
        {
          :status => 'ok',
          :new_release => result[:new_release]
        }.to_json
      else
        send_email_rollback_failed(app_name, email, result) if EMAIL_ENABLED
        response.status = result[:new_release].code
        result[:new_release]
      end
    end
  end

  get '/' do
    @apps_status = APPS.map {|name| {:name => name, :date => $redis.hget(redis_key(name), 'date')}}
    haml :index
  end


  post '/heroku-post' do
    app_name = params.get('app')
    email = params.get('user')
    url = params.get('url')

    logger.log(url)

    init_tests(app_name, email)

    response.status = 201
    {:status => 'ok'}.to_json
  end

  get '/manualtest' do
    app_name = "patata"
    email = "someone@example.com"

    init_tests(app_name, email)

    haml :ok
  end
end
