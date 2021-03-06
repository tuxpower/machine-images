# Classes that encapsulate Mongo replica sets
require 'mongo'
require 'socket'

module MongoDB
  DEFAULT_PORT = 27017

  # MongoDB server exception error messages.
  # NOTE: This script has been tested against:
  #           MongoDB v2.4; ruby mongo driver v2.0.6; aws-sdk v2.1.11 and ruby v2.1

  INIT_FAILED_ERR_MESS_REGEX = "^Database command 'replSetInitiate' failed: already initialized"
  INVALID_STATE_ERR_MESS = 'Replica Set Member has INVALID state!'

  # Number of attempts, and wait in seconds for each attempt, for MongoDB replica set member to
  # complete an initiation (i.e. following a 'replSetInitiate' command).
  INIT_WAIT = 3
  INIT_ATTEMPTS = 60

  # Number of attempts, and wait in seconds for each attempt, for MongoDB replica set member to
  # complete a reconfiguration (i.e. following a 'replSetReconfig' command).
  RECONFIG_WAIT = 10
  RECONFIG_ATTEMPTS = 10

  # MongoDB replic set member states that are considered to be a 'non-failed' state
  NON_FAILED_STATES = [0, 1, 2, 3, 5, 6, 7, 9]

  # MongoDB member states
  STATES = {
      0 => 'STARTUP',
      1 => 'PRIMARY',
      2 => 'SECONDARY',
      3 => 'RECOVERING',
      5 => 'STARTUP2',
      6 => 'UNKNOWN',
      7 => 'ARBITER',
      8 => 'DOWN',
      9 => 'ROLLBACK',
      10 => 'REMOVED'
  }
  STATES.default = 'NONE'

  # Number of attempts, and wait in seconds for each attempt, to connect to the replica set using
  # a host seed list
  CONNECT_WAIT = 10
  CONNECT_ATTEMPTS = 60

  # Maximum attempts to add this host to the replica set before giving up.
  RECONFIG_MAX_ATTEMPTS = 60

  # Class to encapsulate complexities and detail of accessing a MongoDB Replica Set
  class ReplicaSet
    include Util::LoggerMixin

    attr_reader :this_host_key, :config

    def initialize(config)
      @config = config
      this_host_ip = IPSocket.getaddress(Socket.gethostname)
      @this_host_key = "#{this_host_ip}:#{DEFAULT_PORT}"

      @client

      @key = config.key
      rs_security = config.security_data
      @admin_user = rs_security[:admin_user]
      @admin_password = rs_security[:admin_password]
    end

    # Direct local connect on the current host
    def local_connect_auth
      Mongo::Client.new(
          ["127.0.0.1:#{DEFAULT_PORT}"],
          :database => 'admin',
          :user => @admin_user,
          :password => @admin_password,
          :connect_timeout => CONNECT_WAIT,
          # override connection mode (otherwise it detects a replicaset)
          :connect => :direct
      )
    end

    def local_connect_bypass
      Mongo::Client.new(
          ["127.0.0.1:#{DEFAULT_PORT}"],
          :database => 'admin',
          :connect_timeout => CONNECT_WAIT,
          # override connection mode (otherwise it detects a replicaset)
          :connect => :direct
      )
    end

    def local_connect
      client = local_connect_auth
      if has_admin?(client)
        logger.info("Connected locally with auth")
        client
      else
        logger.info("Connected locally using auth bypass")
        local_connect_bypass
      end
    end

    def has_admin?(client)
      begin
        client.database.collections
        return true
      rescue Mongo::Auth::Unauthorized
        return false
      end
    end

    # Connect to the replica set via a host seed list
    def replica_set_connect(mongodb_hosts, read_pref = :primary_preferred)
      Mongo::Client.new(
          mongodb_hosts,
          :user => @admin_user,
          :password => @admin_password,
          :connect_timeout => CONNECT_WAIT,
          :read => {:mode => read_pref},
          :replica_set => @config.name,
          :connect => :replica_set
      )
    end

    # Method to wait for the replica set member to transition to a specific set of states.
    def wait_member_state (
        expected_states = ['PRIMARY'],
        max_wait_attempts = INIT_ATTEMPTS,
        wait_time = INIT_WAIT
    )
      wait_attempts = 0
      while wait_attempts < max_wait_attempts
        begin
          members = self.get_status['members']
          logger.info("looking for #{@this_host_key} in members: #{members}")
          this_member = members.find { |m|
            logger.info("checking against #{m}")
            m['name'] == @this_host_key
          }
          state = this_member['state']
          logger.info("state recovered is #{state}")
        rescue => exception
          logger.info("exception: #{exception.inspect}")
          state = STATES.invert['UNKNOWN']
        end
        logger.info("ReplSet Initiation Member State: #{STATES[state]}")
        logger.info("Waiting for one of #{expected_states.join(', ')}")

        return if expected_states.include? STATES[state]

        wait_attempts++
        sleep(wait_time)
      end
    end

    # Initiate the Replica Set - this is an asynchronous process so if the
    # async parameter is false this method will wait until the initiation is complete
    def initiate(async=true)
      init_config = {
          :_id => @key,
          :members => [{:_id => 0, :host => @this_host_key}]
      }
      @client.database.command(:replSetInitiate => init_config)

      unless async
        expected_member_states = ['PRIMARY']
        max_wait_attempts = INIT_ATTEMPTS
        wait_time = INIT_WAIT
        begin
          # Given the replica set is being initiated on this server
          # then it should become the primary - so wait for it to
          # transition to the primary state
          wait_member_state(
              expected_member_states,
              max_wait_attempts,
              wait_time
          )
        rescue Mongo::Error::OperationFailure => rse
          logger.info("ReplSet Init Error: #{rse.message}")
          if rse.message =~ /#{INIT_FAILED_ERR_MESS_REGEX}/
            logger.info('Replica set previously initiated')
          else
            raise
          end
        end
      end
    end

    def replica_set_reconfig(config, force=false)
      begin
        @client.database.command(:replSetReconfig => config, :force => force)
      rescue Mongo::Error::OperationFailure => error
        raise unless force
        reconfig_attempts = 0
        logger.info('Reconfig Status error:')
        logger.info("#{error.inspect}")
        unless (reconfig_attempts += 1) >= RECONFIG_ATTEMPTS
          sleep(RECONFIG_WAIT)
          retry
        end
      end
    end

    def create_user(client, username, password, roles=['read'], db='admin')
      client.use(db).database.users.create(
          username,
          :password => password,
          :roles => roles
      )
    end

    def create_admin_user
      admin_roles=%w(readWriteAnyDatabase userAdminAnyDatabase dbAdminAnyDatabase clusterAdmin)
      self.create_user(@client, @admin_user, @admin_password, admin_roles)
    end

    # Method to get a failed member candidates to remove from the replica set
    def get_members_to_remove
      begin
        # NOTE: if the replica set could not be found then this *could be* because either
        # all members are faulty *or* there is a network partition. Since it is not easy to
        # determine which is the case, it is only safe to remove members
        # if the replica set has been found
        unless replica_set?
          raise Mongo::Error::OperationFailure,
                'MongoDB Replica Set could not be found.' +
                    ' No members will be removed from config.'
        end
        failed_members = self.get_status['members'].select { |m|
          !(NON_FAILED_STATES.include? m['state'] and m['health'] == 1)
        }
        failed_members.map { |m| m['name'] }
      rescue NoMethodError, Mongo::Error::OperationFailure
        []
      end
    end

    # Method to add and possibly remove existing member 'non-healthy' members.
    def add_or_replace_member(host_key, visibility=true)

      # Get the current replica set configuration
      replica_set_config = get_config

      # we need to increment the config version when updating it
      replica_set_config['version'] += 1 if replica_set_config['version']

      # if we're adding a members then this implies that there might be failed members to remove
      members_to_remove = get_members_to_remove
      if members_to_remove.any?
        logger.info("Target members to remove from Replica Set: #{members_to_remove}...")
        replica_set_config['members'].reject! { |m| members_to_remove.include? m['host'] }
      end

      # unless already a member, add the new member
      # (and minus old failed members if necessary) to configuration
      new_config = replica_set_config
      unless new_config['members'].any? {
          |m| m['host'] == host_key or members_to_remove.include? host_key
        }
        # get an id for the new member where the id is not already in use
        new_member_id = new_config['members'].map { |m| m['_id'] }.max + 1
        new_config['members'] = new_config['members'] << {
            :_id => new_member_id,
            :host => host_key,
            :priority => visibility ? 1 : 0,
            :hidden => (not visibility)
        }
      end

      logger.info('Reconfiguring Replica Set:')
      logger.info("#{new_config.inspect}")
      begin
        self.replica_set_reconfig(new_config, true)
      rescue => ecfg
        logger.info('Reconfiguring Replica Set Failed:')
        logger.info("#{ecfg.inspect}")
        raise
      end

      # reconnect after a reconfiguration
      sleep(1)
      connect

      expected_member_states = %w(PRIMARY SECONDARY STARTUP2)
      max_wait_attempts = RECONFIG_ATTEMPTS
      wait_time = RECONFIG_WAIT
      wait_member_state(
          expected_member_states,
          max_wait_attempts,
          wait_time
      )

    end

    def add_this_host(visibility=true)
      logger.info("Attempting to add #@this_host_ip to Replica Set...")
      self.add_or_replace_member(@this_host_key, visibility)
    end

    def get_config
      local_client = @client.use('local')
      local_client['system.replset'].find().limit(1).first
    end

    def get_status
      @client.database.command(:replSetGetStatus => 1).documents.first
    end

    def name
      begin
        get_config["_id"]
      rescue
        nil
      end
    end

    def replica_set?
      !name.nil?
    end

    def replica_set_connection?
      @client.cluster.topology.replica_set?
    end

    def member_names
      get_status['members'].map { |m| m['name'] }
    end

    def member?(host_key)
      member_names.include?(host_key)
    end

    def authed?
      @client.cluster.servers.first.pool.with_connection do |conn|
        conn.authenticated?
      end
    end

    def disconnect!
      # TODO - when mongo 2.1.0 is released this can be refactored
      unless @client.nil?
        logger.info("Disconnecting from MongoDB.....")
        @client.cluster.servers.each{ |s| s.disconnect! }
        @client = nil
      end
    end

    # Method to connect to the configured replica
    # Either a connection is made to the primary or a local connection is made
    # (if only secondaries or local connections are available).
    def connect
      # if we are reconnecting, let's purge any existing connection
      disconnect!

      seed_list = config.seeds
      unless seed_list.empty?
      then
        (1..CONNECT_ATTEMPTS).each do |find_attempts|
          # Attempt to connect to the Replica Set using the seed list
          # Assumption: if this succeeds then the replica set has already been initiated
          # previously and the service can be located on the network
          # (usually because the autoscaled member is simply adding itself back into the set)
          logger.info("Connecting to MongoDB replica set (#{seed_list}).....")
          begin
            @client = replica_set_connect(seed_list, :primary_preferred)
            logger.info('Connected to MongoDB replica set.....')
            return @client
          rescue => rsce
            # Try a few more times before attempting to initiate the replica set
            # to allow for e.g. temporary network partitions.
            logger.info('Failed to connect to MongoDB replica set.....')
            logger.info("#{rsce.message}")
            # possible network glitches where the other members can't be reached.
            if find_attempts < CONNECT_ATTEMPTS
            then
              logger.info("Sleeping for #{CONNECT_WAIT} seconds.....")
              sleep(CONNECT_WAIT)
              logger.info("Trying again.")
              logger.info("Failed attempts #{find_attempts} "+
                                "of #{CONNECT_ATTEMPTS}.....")
            else
              logger.info('Replica Set can not be located on the network!!')
            end
          end
        end
      end
      # if can't connect to the replica set then connect locally
      logger.info "Can't connect to the Replica Set"
      logger.info 'Attempting to Connect to Mongodb locally...'
      @client = local_connect
      logger.info('Connected locally because Replica Set could not be found.....')
      @client
    end

    private :wait_member_state, :get_members_to_remove

  end
end
