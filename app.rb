require 'sinatra/base'
require 'newrelic_rpm'
require 'rest_client'
require 'json'
require 'digest'
require 'redis'
require 'uri'


APPS = ENV['APPS'].split(';')
HTTP_USER = ENV['HTTP_USER']
HEROKU_API_TOKEN = ENV['HEROKU_API_TOKEN']
REDIS_URI = ENV['REDIS_URI'] || 'redis://localhost:6379/'

class Protected < Sinatra::Base
  if HTTP_USER
    use Rack::Auth::Basic, "Protected Area" do |username, password|
      stored_user, stored_password = HTTP_USER.split(':')
      password_hash = Digest::SHA256.new() << password
      username == stored_user && password_hash.hexdigest == stored_password
    end
  end
  
  post '/:app/deploying/' do
    unless APPS.include?(params[:app])
      response.status = 404
      return {:status => '404', :reason => 'Not found'}.to_json
    end
    payload = JSON.parse(request.body.read)
    
    response.status = 200
    {:status => 'ok'}.to_json
  end

  post '/:app/rollback/' do
  
    unless APPS.include?(params[:app])
      response.status = 404
      return {:status => '404', :reason => 'Not found'}.to_json
    end
    payload = JSON.parse(request.body.read)

    response.status = 200
    {:status => 'ok'}.to_json
  end

  get '/' do
    "This should be an application status list"
  end
end