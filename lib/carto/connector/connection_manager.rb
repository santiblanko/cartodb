require_dependency 'cartodb/central'
require_dependency 'carto/errors'

require_relative 'parameters'
require_relative 'connection_adapter/factory'

module Carto
  class ConnectionManager
    class ConnectionNotFoundError < CartoError
      def initialize(message)
        super(message, 404)
      end
    end

    def initialize(user)
      @user = user
      @user = Carto::User.find(@user.id) unless @user.kind_of?(Carto::User)
    end

    def list_connectors(connections: false, type: nil)
      types = Array(type)

      oauth_connectors = db_connectors = []

      if type.nil? || types.include?(Carto::Connection::TYPE_OAUTH_SERVICE)
        oauth_connectors = Carto::ConnectionManager.valid_oauth_services.map { |service|
          # TODO: check enabled for @user
          is_enabled = true
          # TODO: use presenter
          connector = {
            types: [Carto::Connection::TYPE_OAUTH_SERVICE],
            connector: service,
            enabled: is_enabled,
            available: !@user.connections.exists?(connector: service)
          }
          connector[:connections] = list_connections(connector: service) if connections
          connector
        }
      end

      if type.nil? || types.include?(Carto::Connection::TYPE_DB_CONNECTOR)
        db_connectors = Carto::ConnectionManager.valid_db_connectors.map { |provider|
          is_enabled = Carto::Connector.provider_available?(provider, @user)
          connector = {
            types: [Carto::Connection::TYPE_DB_CONNECTOR],
            connector: provider,
            enabled: is_enabled,
            available: is_enabled
          }
          connector[:connections] = list_connections(connector: provider) if connections
          connector
        }
      end

      # Unify connectors of dual type
      oauth_connectors.each do |oauth_connector|
        db_connector = db_connectors.find { |c| c[:connector] == oauth_connector[:connector] }
        if db_connector.present?
          db_connectors.delete db_connector
          oauth_connector[:types] += db_connector[:types]
          # assume enabled is same for both
          oauth_connector[:available] &&= db_connector[:available]
          if connections
            oauth_connector[:connections] += db_connector[:connections]
          end
        end
      end

      oauth_connectors + db_connectors
    end

    def list_connections(type: nil, connector: nil)
      connections = @user.connections
      connections = connections.where(connection_type: type) if type.present?
      connections = connections.where(connector: connector) if connector.present?
      connections.map { |connection| present_connection(connection) }
    end

    def show_connection(id)
      present_connection @user.connections.find(id)
    end

    def present_connection(connection)
      presented_connection = {
        id: connection.id,
        name: connection.name,
        connector: connection.connector,
        type: connection.connection_type,
      }
      presented_connection[:parameters] = adapter(connection).presented_parameters if connection.parameters.present?
      presented_connection[:token] = adapter(connection).presented_token if connection.token.present?
      # TODO: compute in_use
      presented_connection
    end

    def find_db_connection(provider, parameters)
      @user.db_connections.find { |connection|
        connection.connector == provider &&
         parameters == connection.parameters
      }
    end

    def find_oauth_connection(service)
      @user.oauth_connections.find_by(connector: service)
    end

    def create_db_connection(name:, provider:, parameters:)
      check_db_provider!(provider)
      @user.connections.create!(name: name, connector: provider, parameters: parameters)
    end

    def find_or_create_db_connection(provider, parameters)
      find_db_connection(provider, parameters) ||
      create_db_connection(
        name: generate_connection_name(provider),
        provider: provider,
        parameters: parameters
      )
    end

    # create Oauth connection logic
    #    connection = nil
    #    loop do
    #      # First check if valid connection already exists
    #      connection = connection_manager.fetch_valid_oauth_connection(service)
    #      break if connection
    #      # Give user opportunity to cancel, since next step will remove any existing connection
    #      break if user_cancels_connection()
    #      # let the user authorize our app; existing connection will be dismissed
    #      open_authorization_window(connection_manager.create_oauth_connection_get_url(service))
    #    end
    #    if connection
    #      # connection of dual type (bigquery) we must additionally require parameters from the user and assign them:
    #      connection = assign_db_parameters(service, parameters)
    #    end
    def fetch_valid_oauth_connection(service) # check for valid oauth_connection
      existing_connection = find_oauth_connection(service)
      return existing_connection if oauth_connection_valid?(existing_connection)
    end

    def create_oauth_connection_get_url(service:) # get_url_to_create_oauth_connection
      check_oauth_service!(service)
      existing_connection = find_oauth_connection(service)
      delete_connection(existing_connection.id) if existing_connection.present?
      oauth_connection_url(service)
    end

    # for dual connection only (BigQuery): after fetching a valid oauth connection,
    # parameters should be assigned, which will trigger the final validation
    # this may not be needed: API could perform a regular update
    def assign_db_parameters(service:, parameters:)
      connection = find_oauth_connection(service)
      raise ConnectionNotFoundError.new("Connection not found for service #{service}") unless connection.present?

      connection.update! parameters: parameters
      connection
    end

    # def oauth_connection_completed?(service)
    #   connection = find_oauth_connection(service)
    #   connection.present? && connection.token.present?
    # end

    def oauth_connection_valid?(connection)
      # connection.token.present? && @user.oauths.select(connection.service)&.get_service_datasource&.token_valid?
      connection.get_service_datasource&.token_valid?
    end

    def connection_ready?(id)
      connection = fetch_connection(id)
      case connection.connection_type
      when Carto::Connection::TYPE_DB_CONNECTOR
        true
      when Carto::Connection::TYPE_OAUTH_SERVICE
        oauth_connection_valid?(connection.connector)
      end
    end

    def delete_connection(id)
      connection = fetch_connection(id)
      connection.destroy!
      @user.reload
    end

    def fetch_connection(id)
      @user.connections.find(id)
    end

    def update_db_connection(id:, parameters: nil, name: nil)
      connection = fetch_connection(id)

      new_attributes = {}
      new_attributes[:parameters] = connection.parameters.merge(parameters) if parameters.present?
      new_attributes[:name] = name if name.present?
      connection.update!(new_attributes)
    end

    # This adapts parameters to be passed to a db connector, optionally registering a new connection.
    # Two parameter sets are returned, the first intended to be stored (in a DataImport or Synchronization),
    # which references if possible the connection parameter through a `connection_id` paramter.
    # The second result are the parameters to be passed to a db connector, where connection parameters are
    # included in a `connection` parameter
    #
    # The connection can be provided by any of theas means:
    # * through the separate `connection` argument
    # * referenced by a `connection_id` parameter in `parameters`
    # * passing the connection parameters in `parameters[:connection]` (for backwards compatibility with Import API v1)
    #
    # If the `register` argument is true, and connection parameters are embedded in the `parameters` argument,
    # a new connection will be created if an existing one is not found with the proper parameters.
    # If the `register` argument is not true and connections parameters are provided embedded in `parameters`,
    # then they will be retained as such in the resulting input parameters.
    def adapt_db_connector_parameters(parameters:, connection: nil, register: false)
      connector_parameters = Carto::Connector::Parameters.new(parameters)
      provider = connector_parameters[:provider]
      connection_parameters = connector_parameters[:connection]
      unless connection.present?
        connection_id = connector_parameters[:connection_id]
        if connection_id.present?
          connection = fetch_connection(connection_id)
        elsif connection_parameters.present? && register
          connection = find_or_create_db_connection(provider, connection_parameters)
        end
      end

      input_parameters = connector_parameters.dup

      if connection.present?
        if provider.present?
          raise Carto::ParamInvalidError.new("provider: #{provider}", [connection.connector], 422) if provider != connection.connector
        else
          connector_parameters.merge! provider: connection.connector
        end
        connection_parameters = adapter(connection).filtered_connection_parameters

        connector_parameters.merge! connection: connection_parameters
        connector_parameters.delete :connection_id
        input_parameters.merge! connection_id: connection.id
        input_parameters.delete :connection
      end

      if legacy_oauth_db_connection?(connector_parameters)
        connection_parameters = connector_parameters[:connection] || {}
        connection_parameters[:refresh_token] = @user.oauths&.select(connector_parameters[:provider])&.token
        connector_parameters[:connection] = connection_parameters
      end

      [input_parameters, connector_parameters]
    end

    def legacy_oauth_db_connection?(connector_parameters)
      return false unless connector_parameters[:provider] == 'bigquery'

      credentials = [:service_token, :refresh_token, :access_token]
      connection_parameters = (connector_parameters[:connection] || {}).keys
      (credentials & connection_parameters).empty?
    end

    def self.adapter(connection)
      Carto::ConnectionAdapter::Factory.adapter_for_connection(connection)
    end

    def self.singleton_connector?(connection)
      adapter(connection).singleton?
    end

    def self.errors(connection)
      errors = []
      case connection.connection_type
      when Carto::Connection::TYPE_OAUTH_SERVICE
        errors << "Not a valid OAuth connector: #{connection.connector}" unless connection.connector.in?(valid_oauth_services)
      when Carto::Connection::TYPE_DB_CONNECTOR
        if !connection.connector.in?(valid_db_connectors)
          errors << "Not a valid DB connector: #{connection.connector}"
        end
      end
      errors + adapter(connection).errors
    end

    def manage_create(connection)
      adapter(connection).create
    end

    def manage_destroy(connection)
      adapter(connection).destroy
    end

    def manage_update(connection)
      adapter(connection).update
    end

    def check(connection)
      if connection.connector_type == Carto::Connection::TYPE_OAUTH_SERVICE
        oauth_connection_valid?(connection.connector)
      else
        connector = Carto::Connector.new(parameters: {}, connection: connection, user: @user, logger: nil)
        connector.check_connection
      end
    end

    private

    def adapter(connection)
      self.class.adapter(connection)
    end

    def generate_connection_name(provider)
      # FIXME: this could produce name collisions
      n = @user.db_connections.where(connector: provider).count
      n > 0 ? "#{provider}_#{n+1}" : provider
    end

    def oauth_connection_url(service) # returns auth_url, doesn't actually create connection
      DataImportsService.new.get_service_auth_url(@user, service)
    end

    def self.valid_oauth_services
      CartoDB::Datasources::DatasourcesFactory.get_all_oauth_datasources.select { |service|
        # FIXME: this includes twitter...
        # begin
        #   config, _ = CartoDB::Datasources::DatasourcesFactory.get_config(service)
        #   config.present?
        # rescue MissingConfigurationError
        #   false
        # end
        Cartodb.get_config(:oauth, service).present?
      }
    end

    def self.valid_db_connectors
      Carto::Connector.providers.keys
    end

    def check_oauth_service!(service)
      # TODO: check also that is enabled for @user
      valid_services = Carto::ConnectionManager.valid_oauth_services
      raise Carto::ParamInvalidError.new("connector: #{service}", valid_services, 422) unless service.in?(valid_services)
    end

    def check_db_provider!(provider)
      # TODO: check also that is enabled for @user
      valid_providers = Carto::ConnectionManager.valid_db_connectors
      raise Carto::ParamInvalidError.new("connector: #{provider}", valid_providers, 422) unless provider.in?(valid_providers)
    end
  end
end
