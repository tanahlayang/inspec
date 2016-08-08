# encoding: utf-8
# author: Dominik Richter
# author: Christoph Hartmann

require 'logger'
require 'fileutils'
require 'molinillo'
require 'inspec/errors'

module Inspec
  class Resolver
    def self.resolve(requirements, vendor_index, cwd, opts = {})
      reqs = requirements.map do |req|
        Requirement.from_metadata(req, cwd: cwd) ||
          fail("Cannot initialize dependency: #{req}")
      end

      new(vendor_index, opts).resolve(reqs)
    end

    def initialize(vendor_index, opts = {})
      @logger = opts[:logger] || Logger.new(nil)
      @debug_mode = false # TODO: hardcoded for now, grab from options

      @vendor_index = vendor_index
      @resolver = Molinillo::Resolver.new(self, self)
      @search_cache = {}
    end

    # Resolve requirements.
    #
    # @param requirements [Array(Inspec::requirement)] Array of requirements
    # @return [Array(String)] list of resolved dependency paths
    def resolve(requirements)
      requirements.each(&:pull)
      @base_dep_graph = Molinillo::DependencyGraph.new
      @dep_graph = @resolver.resolve(requirements, @base_dep_graph)
      arr = @dep_graph.map(&:payload)
      Hash[arr.map { |e| [e.name, e] }]
    rescue Molinillo::VersionConflict => e
      raise VersionConflict.new(e.conflicts.keys.uniq, e.message)
    rescue Molinillo::CircularDependencyError => e
      names = e.dependencies.sort_by(&:name).map { |d| "profile '#{d.name}'" }
      raise CyclicDependencyError,
            'Your profile has requirements that depend on each other, creating '\
            "an infinite loop. Please remove #{names.count > 1 ? 'either ' : ''} "\
            "#{names.join(' or ')} and try again."
    end

    # --------------------------------------------------------------------------
    # SpecificationProvider

    # Search for the specifications that match the given dependency.
    # The specifications in the returned array will be considered in reverse
    # order, so the latest version ought to be last.
    # @note This method should be 'pure', i.e. the return value should depend
    #   only on the `dependency` parameter.
    #
    # @param [Object] dependency
    # @return [Array<Object>] the specifications that satisfy the given
    #   `dependency`.
    def search_for(dep)
      unless dep.is_a?(Inspec::Requirement)
        fail 'Internal error: Dependency resolver requires an Inspec::Requirement object for #search_for(dependency)'
      end
      @search_cache[dep] ||= uncached_search_for(dep)
    end

    def uncached_search_for(dep)
      # pre-cached and specified dependencies
      return [dep] unless dep.profile.nil?

      results = @vendor_index.find(dep)
      return [] unless results.any?

      # TODO: load dep from vendor index
      # vertex = @dep_graph.vertex_named(dep.name)
      # locked_requirement = vertex.payload.requirement if vertex
      fail NotImplementedError, "load dependency #{dep} from vendor index"
    end

    # Returns the dependencies of `specification`.
    # @note This method should be 'pure', i.e. the return value should depend
    #   only on the `specification` parameter.
    #
    # @param [Object] specification
    # @return [Array<Object>] the dependencies that are required by the given
    #   `specification`.
    def dependencies_for(specification)
      specification.profile.metadata.dependencies
    end

    # Determines whether the given `requirement` is satisfied by the given
    # `spec`, in the context of the current `activated` dependency graph.
    #
    # @param [Object] requirement
    # @param [DependencyGraph] activated the current dependency graph in the
    #   resolution process.
    # @param [Object] spec
    # @return [Boolean] whether `requirement` is satisfied by `spec` in the
    #   context of the current `activated` dependency graph.
    def requirement_satisfied_by?(requirement, _activated, spec)
      requirement.matches_spec?(spec) || spec.is_a?(Inspec::Profile)
    end

    # Returns the name for the given `dependency`.
    # @note This method should be 'pure', i.e. the return value should depend
    #   only on the `dependency` parameter.
    #
    # @param [Object] dependency
    # @return [String] the name for the given `dependency`.
    def name_for(dependency)
      unless dependency.is_a?(Inspec::Requirement)
        fail 'Internal error: Dependency resolver requires an Inspec::Requirement object for #name_for(dependency)'
      end
      dependency.name
    end

    # @return [String] the name of the source of explicit dependencies, i.e.
    #   those passed to {Resolver#resolve} directly.
    def name_for_explicit_dependency_source
      'inspec.yml'
    end

    # @return [String] the name of the source of 'locked' dependencies, i.e.
    #   those passed to {Resolver#resolve} directly as the `base`
    def name_for_locking_dependency_source
      'inspec.lock'
    end

    # Sort dependencies so that the ones that are easiest to resolve are first.
    # Easiest to resolve is (usually) defined by:
    #   1) Is this dependency already activated?
    #   2) How relaxed are the requirements?
    #   3) Are there any conflicts for this dependency?
    #   4) How many possibilities are there to satisfy this dependency?
    #
    # @param [Array<Object>] dependencies
    # @param [DependencyGraph] activated the current dependency graph in the
    #   resolution process.
    # @param [{String => Array<Conflict>}] conflicts
    # @return [Array<Object>] a sorted copy of `dependencies`.
    def sort_dependencies(dependencies, activated, conflicts)
      dependencies.sort_by do |dependency|
        name = name_for(dependency)
        [
          activated.vertex_named(name).payload ? 0 : 1,
          # amount_constrained(dependency), # TODO
          conflicts[name] ? 0 : 1,
          # activated.vertex_named(name).payload ? 0 : search_for(dependency).count, # TODO
        ]
      end
    end

    # Returns whether this dependency, which has no possible matching
    # specifications, can safely be ignored.
    #
    # @param [Object] dependency
    # @return [Boolean] whether this dependency can safely be skipped.
    def allow_missing?(dependency)
      # TODO
      false
    end

    # --------------------------------------------------------------------------
    # UI

    include Molinillo::UI

    # The {IO} object that should be used to print output. `STDOUT`, by default.
    #
    # @return [IO]
    def output
      self
    end

    def print(what = '')
      @logger.info(what)
    end
    alias puts print
  end

  class Package
    def initialize(path, version)
      @path = path
      @version = version
    end
  end

  class VendorIndex
    attr_reader :list, :path
    def initialize(path)
      @path = path
      FileUtils.mkdir_p(path) unless File.directory?(path)
      @list = Dir[File.join(path, '*')].map { |x| load_path(x) }
    end

    def find(_dependency)
      # TODO
      fail NotImplementedError, '#find(dependency) on VendorIndex seeks implementation.'
    end

    private

    def load_path(_path)
      # TODO
      fail NotImplementedError, '#load_path(path) on VendorIndex wants to be implemented.'
    end
  end

  class Requirement
    attr_reader :name, :dep, :cwd, :opts
    def initialize(name, dep, cwd, opts)
      @name = name
      @dep = Gem::Dependency.new(name, Gem::Requirement.new(Array(dep)), :runtime)
      @opts = opts
      @cwd = cwd
    end

    def matches_spec?(spec)
      params = spec.profile.metadata.params
      @dep.match?(params[:name], params[:version])
    end

    def pull
      case
      when @opts[:path] then pull_path(@opts[:path])
      else
        # TODO: should default to supermarket
        fail 'You must specify the source of the dependency (for now...)'
      end
    end

    def path
      @path || pull
    end

    def profile
      return nil if path.nil?
      @profile ||= Inspec::Profile.for_target(path, {})
    end

    def self.from_metadata(dep, opts)
      fail 'Cannot load empty dependency.' if dep.nil? || dep.empty?
      name = dep[:name] || fail('You must provide a name for all dependencies')
      version = dep[:version]
      new(name, version, opts[:cwd], dep)
    end

    def to_s
      @dep.to_s
    end

    private

    def pull_path(path)
      abspath = File.absolute_path(path, @cwd)
      fail "Dependency path doesn't exist: #{path}" unless File.exist?(abspath)
      fail "Dependency path isn't a folder: #{path}" unless File.directory?(abspath)
      @path = abspath
      true
    end
  end

  class SupermarketDependency
    def initialize(url, requirement)
      @url = url
      @requirement = requirement
    end

    def self.load(dep)
      return nil if dep.nil?
      sname = dep[:supermarket]
      return nil if sname.nil?
      surl = dep[:supermarket_url] || 'default_url...'
      requirement = dep[:version]
      url = surl + '/' + sname
      new(url, requirement)
    end
  end

  class Dependencies
    attr_reader :list, :vendor_path

    # initialize
    #
    # @param cwd [String] current working directory for relative path includes
    # @param vendor_path [String] path which contains vendored dependencies
    # @return [dependencies] this
    def initialize(cwd, vendor_path)
      @cwd = cwd
      @vendor_path = vendor_path || File.join(Dir.home, '.inspec', 'cache')
      @list = nil
    end

    # 1. Get dependencies, pull things to a local cache if necessary
    # 2. Resolve dependencies
    #
    # @param dependencies [Gem::Dependency] list of dependencies
    # @return [nil]
    def vendor(dependencies)
      return if dependencies.nil? || dependencies.empty?
      @vendor_index ||= VendorIndex.new(@vendor_path)
      @list = Resolver.resolve(dependencies, @vendor_index, @cwd)
    end
  end
end
