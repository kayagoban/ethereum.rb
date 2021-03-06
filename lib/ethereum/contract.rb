module Ethereum
  class Contract

    attr_reader :address
    attr_accessor :code, :name, :abi, :class_object, :sender, :deployment, :client
    attr_accessor :events, :functions, :constructor_inputs
    attr_accessor :call_raw_proxy, :call_proxy, :transact_proxy, :transact_and_wait_proxy
    attr_accessor :new_filter_proxy, :get_filter_logs_proxy, :get_filter_change_proxy

    def initialize(name, code, abi, client = Ethereum::Singleton.instance)
      @name = name
      @code = code
      @abi = abi
      @constructor_inputs, @functions, @events = Ethereum::Abi.parse_abi(abi)
      @formatter = Ethereum::Formatter.new
      @client = client
      @sender = client.default_account
      @encoder = Encoder.new
      @decoder = Decoder.new
    end

    def self.create(file: nil, client: Ethereum::Singleton.instance, code: nil, abi: nil, address: nil, name: nil)
      contract = nil
      if file.present?
        contracts = Ethereum::Initializer.new(file, client).build_all
        raise "No contracts complied" if contracts.empty?
        contract = contracts.first.class_object.new
      else
        abi = JSON.parse(abi) if abi.is_a? String
        contract = Ethereum::Contract.new(name, code, abi, client)
        contract.build
        contract = contract.class_object.new
      end
      contract.address = address
      contract
    end


    def address=(addr)
      @address = addr
      @events.each do |event|
        event.set_address(addr)
        event.set_client(@client)
      end
    end

    def deploy(*params)
      if @constructor_inputs.present?
        raise "Missing constructor parameter" and return if params.length != @constructor_inputs.length
      end
      deploy_arguments = @encoder.encode_arguments(@constructor_inputs, params)
      payload = "0x" + @code + deploy_arguments
      tx = @client.eth_send_transaction({from: sender, data: payload})["result"]
      raise "Failed to deploy, did you unlock #{sender} account? Transaction hash: #{deploytx}" if tx.nil? || tx == "0x0000000000000000000000000000000000000000000000000000000000000000"
      @deployment = Ethereum::Deployment.new(tx, @client)
    end

    def deploy_and_wait(*params, **args, &block)
      deploy(*params)
      @deployment.wait_for_deployment(**args, &block)
      self.events.each do |event|
        event.set_address(@address)
        event.set_client(@client)
      end
      @address = @deployment.contract_address
    end

    def estimate(*params)
      deploy_arguments = ""
      if @constructor_inputs.present?
        raise "Wrong number of arguments in a constructor" and return if params.length != @constructor_inputs.length
        deploy_arguments = @encoder.encode_arguments(@constructor_inputs, params)
      end
      deploy_payload = @code + deploy_arguments
      result = @client.eth_estimate_gas({from: @sender, data: "0x" + deploy_payload})
      @decoder.decode_int(result["result"])
    end

    def call_raw(fun, *args)
      payload = fun.signature + @encoder.encode_arguments(fun.inputs, args)
      raw_result = @client.eth_call({to: @address, from: @sender, data: "0x" + payload})
      raw_result = raw_result["result"]
      output = @decoder.decode_arguments(fun.outputs, raw_result)
      return {data: "0x" + payload, raw: raw_result, formatted: output}
    end

    def call(fun, *args)
      output = call_raw(fun, *args)[:formatted]
      if output.length == 1
        return output[0]
      else
        return output
      end
    end

    def transact(fun, *args)
      payload = fun.signature + @encoder.encode_arguments(fun.inputs, args)
      txid = @client.eth_send_transaction({to: @address, from: @sender, data: "0x" + payload})["result"]
      return Ethereum::Transaction.new(txid, @client, payload, args)
    end

    def transact_and_wait(fun, *args)
      tx = transact(fun, *args)
      tx.wait_for_miner
      return tx
    end

    def create_filter(evt, **params)
      params[:to_block] ||= "latest"
      params[:from_block] ||= "0x0"
      params[:address] ||= @address
      params[:topics] = @encoder.ensure_prefix(evt.signature)
      payload = {topics: [params[:topics]], fromBlock: params[:from_block], toBlock: params[:to_block], address: @encoder.ensure_prefix(params[:address])}
      filter_id = @client.eth_new_filter(payload)
      return @decoder.decode_int(filter_id["result"])
    end

    def parse_filter_data(evt, logs)
      formatter = Ethereum::Formatter.new
      collection = []
      logs["result"].each do |result|
        inputs = evt.input_types
        outputs = inputs.zip(result["topics"][1..-1])
        data = {blockNumber: result["blockNumber"].hex, transactionHash: result["transactionHash"], blockHash: result["blockHash"], transactionIndex: result["transactionIndex"].hex, topics: []} 
        outputs.each do |output|
          data[:topics] << formatter.from_payload(output)
        end
        collection << data 
      end
      return collection
    end

    def get_filter_logs(evt, filter_id)
      parse_filter_data evt, @client.eth_get_filter_logs(filter_id)
    end

    def get_filter_changes(evt, filter_id)
      parse_filter_data evt, @client.eth_get_filter_changes(filter_id)
    end

    def function_name(fun)
      count = functions.select {|x| x.name == fun.name }.count
      name = (count == 1) ? "#{fun.name.underscore}" : "#{fun.name.underscore}__#{fun.inputs.collect {|x| x.type}.join("__")}"
      name.to_sym
    end

    def build
      class_name = @name.camelize
      parent = self
      create_function_proxies
      create_event_proxies
      class_methods = Class.new do
        extend Forwardable
        def_delegators :parent, :abi, :deployment, :events
        def_delegators :parent, :estimate, :deploy, :deploy_and_wait
        def_delegators :parent, :address, :address=, :sender, :sender=
        def_delegator :parent, :call_raw_proxy, :call_raw
        def_delegator :parent, :call_proxy, :call
        def_delegator :parent, :transact_proxy, :transact
        def_delegator :parent, :transact_and_wait_proxy, :transact_and_wait
        def_delegator :parent, :new_filter_proxy, :new_filter
        def_delegator :parent, :get_filter_logs_proxy, :get_filter_logs
        def_delegator :parent, :get_filter_change_proxy, :get_filter_changes
        define_method :parent do
          parent
        end
      end
      Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
      Object.const_set(class_name, class_methods)
      @class_object = class_methods
    end

    private
      def create_function_proxies
        parent = self
        call_raw_proxy, call_proxy, transact_proxy, transact_and_wait_proxy = Class.new, Class.new, Class.new, Class.new
        @functions.each do |fun|
          call_raw_proxy.send(:define_method, parent.function_name(fun)) { |*args| parent.call_raw(fun, *args) }
          call_proxy.send(:define_method, parent.function_name(fun)) { |*args| parent.call(fun, *args) }
          transact_proxy.send(:define_method, parent.function_name(fun)) { |*args| parent.transact(fun, *args) }
          transact_and_wait_proxy.send(:define_method, parent.function_name(fun)) { |*args| parent.transact_and_wait(fun, *args) }
        end
        @call_raw_proxy, @call_proxy, @transact_proxy, @transact_and_wait_proxy =  call_raw_proxy.new, call_proxy.new, transact_proxy.new, transact_and_wait_proxy.new
      end

      def create_event_proxies
        parent = self
        new_filter_proxy, get_filter_logs_proxy, get_filter_change_proxy = Class.new, Class.new, Class.new
        events.each do |evt|
          new_filter_proxy.send(:define_method, evt.name.underscore) { |*args| parent.create_filter(evt, *args) }
          get_filter_logs_proxy.send(:define_method, evt.name.underscore) { |*args| parent.get_filter_logs(evt, *args) }
          get_filter_change_proxy.send(:define_method, evt.name.underscore) { |*args| parent.get_filter_changes(evt, *args) }
        end
        @new_filter_proxy, @get_filter_logs_proxy, @get_filter_change_proxy = new_filter_proxy.new, get_filter_logs_proxy.new, get_filter_change_proxy.new
      end
  end
end
