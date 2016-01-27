require 'chef/event_dispatch/dsl'
require_relative 'dsl'
require_relative 'chef_patches'
require 'chef/recipe'
require 'chef/resource'
require 'chef/provider'

module Choregraphie
  class Choregraphie

    attr_reader :name

    def initialize(name, &block)
      @name = name
      @before = []
      @after  = []

      # read all available primitives and make them available with a method
      # using their name. It allows to call `check_file '/tmp/titi'` to
      # instanciate the CheckFile primitive
      Primitive.all.each do |klass|
        instance_eval <<-EOM
        def #{klass.primitive_name}(*args)
          primitive = ::#{klass}.new(*args)
          primitive.register(self)
        end
        EOM
      end

      # this + method_missing allows to access method defined outside of the
      # block (in the recipe context for instance)
      @self_before_instance_eval = eval "self", block.binding
      instance_eval &block
    end

    def method_missing(method, *args, &block)
      @self_before_instance_eval.send method, *args, &block
    end

    def before(&block)
      if block
        Chef::Log.debug("Registering a before block for #{@name}")
        @before << block
      end
      @before
    end

    def after(&block)
      if block
        Chef::Log.debug("Registering an after block for #{@name}")
        @after << block
      end
      @after
    end

    def on(event)
      Chef::Log.warn("Registering on #{event} for #{@name}")
      case event
      when String # resource name
        resource_name = event
        before_events = before
        after_events  = after
        Chef.event_handler do
          on :resource_current_state_loaded do |resource, action, current_resource|
            if resource.to_s == resource_name
              Chef::Log.debug "Receiving resource_current_state_loaded for #{resource_name}"
              provider = resource.provider_for_action(action) # TODO avoid new class creation
              if provider.whyrun_supported?
                # TODO: what about providers than contains only chef resources ? (and no converge_by)
                # we have to support embedded chef runs that are generated by these cases (use_inline_resources?)
                Chef::Log.debug("Delaying before block to actual converge_by call for #{resource_name}")
              else
                before_events.each do |b| b.call(resource) end
              end
            end
          end
          on :resource_pre_converge do |resource, action, description|
            if resource.to_s == resource_name
              Chef::Log.debug "Receiving pre_converge for #{resource_name}: #{description}"
              provider = resource.provider_for_action(action) # TODO avoid new class creation
              if provider.whyrun_supported?
                # before blocks have been delayed
                before_events.each do |b| b.call(resource) end
              end
            end
          end
          on :resource_updated do |resource|
            if resource.to_s == resource_name
              Chef::Log.debug "Receiving resource_completed for #{resource_name}"
              after_events.each do |b| b.call(resource) end
            end
          end
        end
      when Symbol
        #TODO
        raise "Symbol type is not yet supported"
      end
    end

  end
end

Chef::Recipe.send(:include, Choregraphie::DSL)
Chef::Resource.send(:include, Choregraphie::DSL)
Chef::Provider.send(:include, Choregraphie::DSL)
