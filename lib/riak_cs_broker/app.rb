ENV["RACK_ENV"] ||= "development"
require 'bundler/setup'
Bundler.require(:default, ENV["RACK_ENV"].to_sym)

require 'json'
STDOUT.sync=true
$:.unshift(File.expand_path('../../', __FILE__))
require 'riak_cs_broker/config'
require 'riak_cs_broker/service_instances'

Dotenv.load
module RiakCsBroker
  class App < Sinatra::Base
    use Rack::Auth::Basic, "Cloud Foundry Riak CS Service Broker" do |username, password|
      [username, password] == [Config.basic_auth[:username], Config.basic_auth[:password]]
    end

    before do
      content_type "application/json"
      Excon.defaults[:ssl_verify_peer] = Config.ssl_validation
    end

    get '/v2/catalog' do
      RiakCsBroker::Config.catalog.to_json
    end

    put '/v2/service_instances/:id' do
      begin
        if instances.include?(params[:id])
          status 409
          logger.info("Could not provision #{params[:id]} because it already exists.")
        else
          instances.add(params[:id])
          status 201
        end
        "{}"
      rescue RiakCsBroker::ServiceInstances::ClientError, RiakCsBroker::Config::ConfigError => e
        logger.error(e.message)
        logger.error(e.backtrace)
        status 500
        { description: e.message }.to_json
      end
    end

    delete '/v2/service_instances/:id' do
      begin
        instances.remove(params[:id])
        status 200
        "{}"
      rescue RiakCsBroker::ServiceInstances::InstanceNotEmptyError
        logger.info("Could not deprovision a non-empty instance #{params[:id]}")
        status 409
        { description: "Could not unprovision because instance is not empty" }.to_json
      rescue RiakCsBroker::ServiceInstances::InstanceNotFoundError
        logger.info("Could not find the instance #{params[:id]}")
        status 410
        "{}"
      rescue RiakCsBroker::ServiceInstances::ClientError, RiakCsBroker::Config::ConfigError => e
        logger.error(e.message)
        logger.error(e.backtrace)
        status 500
        { description: e.message }.to_json
      end
    end

    put '/v2/service_instances/:id/service_bindings/:binding_id' do
      begin
        credentials = instances.bind(params[:id], params[:binding_id])
        status 201
        { "credentials" => credentials }.to_json
      rescue ServiceInstances::InstanceNotFoundError => e
        logger.info("Could not bind a nonexistent instance for #{params[:id]}")
        status 404
        { description: "Could not bind a nonexistent instance for #{params[:id]}" }.to_json
      rescue ServiceInstances::BindingAlreadyExistsError => e
        logger.info("Could not bind because of a conflict: #{e.message}")
        status 409
        "{}"
      rescue ServiceInstances::ServiceUnavailableError => e
        logger.error("Service unavailable: #{e.message}")
        status 503
        { description: "Could not bind because service is unavailable" }.to_json
      rescue RiakCsBroker::ServiceInstances::ClientError, RiakCsBroker::Config::ConfigError => e
        logger.error(e.message)
        logger.error(e.backtrace)
        status 500
        { description: e.message }.to_json
      end
    end

    delete '/v2/service_instances/:id/service_bindings/:binding_id' do
      begin
        instances.unbind(params[:id], params[:binding_id])
        status 200
        "{}"
      rescue ServiceInstances::InstanceNotFoundError => e
        logger.info("Could not unbind from a nonexistent instance #{params[:id]}")
        status 410
        "{}"
      rescue ServiceInstances::BindingNotFoundError => e
        logger.info("Could not find the binding #{params[:binding_id]}")
        status 410
        "{}"
      rescue ServiceInstances::ServiceUnavailableError => e
        logger.error("Service unavailable: #{e.message}")
        status 503
        { description: "Could not bind because service is unavailable" }.to_json
      rescue RiakCsBroker::ServiceInstances::ClientError, RiakCsBroker::Config::ConfigError => e
        logger.error(e.message)
        logger.error(e.backtrace)
        status 500
        { description: e.message }.to_json
      end
    end

    def instances
      @instances ||= ServiceInstances.new(Config.riak_cs)
    end

    def logger
      settings.logger
    end
  end

  App.set :logger, Logger.new(STDOUT)
end