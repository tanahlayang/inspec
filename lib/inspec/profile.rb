# encoding: utf-8
# Copyright 2015 Dominik Richter. All rights reserved.
# author: Dominik Richter
# author: Christoph Hartmann

require 'forwardable'
require 'inspec/polyfill'
require 'inspec/fetcher'
require 'inspec/source_reader'
require 'inspec/metadata'
require 'inspec/dependencies'

module Inspec
  class Profile # rubocop:disable Metrics/ClassLength
    extend Forwardable

    def self.resolve_target(target, opts)
      # Fetchers retrieve file contents
      opts[:target] = target
      fetcher = Inspec::Fetcher.resolve(target)
      if fetcher.nil?
        fail("Could not fetch inspec profile in #{target.inspect}.")
      end
      # Source readers understand the target's structure and provide
      # access to tests, libraries, and metadata
      reader = Inspec::SourceReader.resolve(fetcher.relative_target)
      if reader.nil?
        fail("Don't understand inspec profile in #{target.inspect}, it "\
             "doesn't look like a supported profile structure.")
      end
      reader
    end

    def self.for_target(target, opts)
      new(resolve_target(target, opts), opts)
    end

    attr_reader :source_reader
    attr_accessor :runner_context
    def_delegator :@source_reader, :tests
    def_delegator :@source_reader, :libraries
    def_delegator :@source_reader, :metadata

    # rubocop:disable Metrics/AbcSize
    def initialize(source_reader, options = nil)
      @options = options || {}
      @target = @options.delete(:target)
      @logger = @options[:logger] || Logger.new(nil)
      @source_reader = source_reader
      @profile_id = @options[:id]
      @runner_context = nil
      Metadata.finalize(@source_reader.metadata, @profile_id)
    end

    def params
      @params ||= load_params
    end

    def info
      res = params.dup
      # add information about the controls
      controls = res[:controls].map do |id, rule|
        next if id.to_s.empty?
        data = rule.dup
        data.delete(:checks)
        data[:impact] ||= 0.5
        data[:impact] = 1.0 if data[:impact] > 1.0
        data[:impact] = 0.0 if data[:impact] < 0.0
        [id, data]
      end
      res[:controls] = Hash[controls.compact]

      # add information about the required attributes
      res[:attributes] = res[:attributes].map(&:to_hash) unless res[:attributes].nil? || res[:attributes].empty?
      res
    end

    # Check if the profile is internall well-structured. The logger will be
    # used to print information on errors and warnings which are found.
    #
    # @return [Boolean] true if no errors were found, false otherwise
    def check # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
      # initial values for response object
      result = {
        summary: {
          valid: false,
          timestamp: Time.now.iso8601,
          location: @target,
          profile: nil,
          controls: 0,
        },
        errors: [],
        warnings: [],
      }

      entry = lambda { |file, line, column, control, msg|
        {
          file: file,
          line: line,
          column: column,
          control_id: control,
          msg: msg,
        }
      }

      warn = lambda { |file, line, column, control, msg|
        @logger.warn(msg)
        result[:warnings].push(entry.call(file, line, column, control, msg))
      }

      error = lambda { |file, line, column, control, msg|
        @logger.error(msg)
        result[:errors].push(entry.call(file, line, column, control, msg))
      }

      @logger.info "Checking profile in #{@target}"
      meta_path = @source_reader.target.abs_path(@source_reader.metadata.ref)
      if meta_path =~ /metadata\.rb$/
        warn.call(@target, 0, 0, nil, 'The use of `metadata.rb` is deprecated. Use `inspec.yml`.')
      end

      # verify metadata
      m_errors, m_warnings = metadata.valid
      m_errors.each { |msg| error.call(meta_path, 0, 0, nil, msg) }
      m_warnings.each { |msg| warn.call(meta_path, 0, 0, nil, msg) }
      m_unsupported = metadata.unsupported
      m_unsupported.each { |u| warn.call(meta_path, 0, 0, nil, "doesn't support: #{u}") }
      @logger.info 'Metadata OK.' if m_errors.empty? && m_unsupported.empty?

      # extract profile name
      result[:summary][:profile] = metadata.params[:name]

      # check if the profile is using the old test directory instead of the
      # new controls directory
      if @source_reader.tests.keys.any? { |x| x =~ %r{^test/$} }
        warn.call(@target, 0, 0, nil, 'Profile uses deprecated `test` directory, rename it to `controls`.')
      end

      count = controls_count
      result[:summary][:controls] = count
      if count == 0
        warn.call(nil, nil, nil, nil, 'No controls or tests were defined.')
      else
        @logger.info("Found #{count} controls.")
      end

      # iterate over hash of groups
      params[:controls].each { |id, control|
        sfile = control[:source_location][:ref]
        sline = control[:source_location][:line]
        error.call(sfile, sline, nil, id, 'Avoid controls with empty IDs') if id.nil? or id.empty?
        next if id.start_with? '(generated '
        warn.call(sfile, sline, nil, id, "Control #{id} has no title") if control[:title].to_s.empty?
        warn.call(sfile, sline, nil, id, "Control #{id} has no description") if control[:desc].to_s.empty?
        warn.call(sfile, sline, nil, id, "Control #{id} has impact > 1.0") if control[:impact].to_f > 1.0
        warn.call(sfile, sline, nil, id, "Control #{id} has impact < 0.0") if control[:impact].to_f < 0.0
        warn.call(sfile, sline, nil, id, "Control #{id} has no tests defined") if control[:checks].nil? or control[:checks].empty?
      }

      # profile is valid if we could not find any error
      result[:summary][:valid] = result[:errors].empty?

      @logger.info 'Control definitions OK.' if result[:warnings].empty?
      result
    end

    def controls_count
      params[:controls].values.length
    end

    # generates a archive of a folder profile
    # assumes that the profile was checked before
    def archive(opts)
      # check if file exists otherwise overwrite the archive
      dst = archive_name(opts)
      if dst.exist? && !opts[:overwrite]
        @logger.info "Archive #{dst} exists already. Use --overwrite."
        return false
      end

      # remove existing archive
      File.delete(dst) if dst.exist?
      @logger.info "Generate archive #{dst}."

      # filter files that should not be part of the profile
      # TODO ignore all .files, but add the files to debug output

      # display all files that will be part of the archive
      @logger.debug 'Add the following files to archive:'
      root_path = @source_reader.target.prefix
      files = @source_reader.target.files
      files.each { |f| @logger.debug '    ' + f }

      if opts[:zip]
        # generate zip archive
        require 'inspec/archive/zip'
        zag = Inspec::Archive::ZipArchiveGenerator.new
        zag.archive(root_path, files, dst)
      else
        # generate tar archive
        require 'inspec/archive/tar'
        tag = Inspec::Archive::TarArchiveGenerator.new
        tag.archive(root_path, files, dst)
      end

      @logger.info 'Finished archive generation.'
      true
    end

    def locked_dependencies
      @locked_dependencies ||= load_dependencies
    end

    private

    # Create an archive name for this profile and an additional options
    # configuration. Either use :output or generate the name from metadata.
    #
    # @param [Hash] configuration options
    # @return [Pathname] path for the archive
    def archive_name(opts)
      if (name = opts[:output])
        return Pathname.new(name)
      end

      name = params[:name] ||
             fail('Cannot create an archive without a profile name! Please '\
             'specify the name in metadata or use --output to create the archive.')
      ext = opts[:zip] ? 'zip' : 'tar.gz'
      slug = name.downcase.strip.tr(' ', '-').gsub(/[^\w-]/, '_')
      Pathname.new(Dir.pwd).join("#{slug}.#{ext}")
    end

    def load_params
      params = @source_reader.metadata.params
      params[:name] = @profile_id unless @profile_id.nil?
      load_checks_params(params)
      @profile_id ||= params[:name]
      params
    end

    def load_checks_params(params)
      params[:controls] = controls = {}
      params[:groups] = groups = {}
      prefix = @source_reader.target.prefix || ''

      if @runner_context.nil?
        # we're checking a profile, we don't care if it runs on the host machine
        opts = @options.dup
        opts[:ignore_supports] = true
        runner = Runner.new(
          id: @profile_id,
          backend: :mock,
          test_collector: opts.delete(:test_collector),
        )
        runner.add_profile(self, opts)
        runner.rules.values.each do |rule|
          f = load_rule_filepath(prefix, rule)
          load_rule(rule, f, controls, groups)
        end
        params[:attributes] = runner.attributes
      else
        # load from context
        @runner_context.rules.values.each do |rule|
          f = load_rule_filepath(prefix, rule)
          load_rule(rule, f, controls, groups)
        end
        params[:attributes] = @runner_context.attributes
      end
      params
    end

    def load_rule_filepath(prefix, rule)
      file = rule.instance_variable_get(:@__file)
      file = file[prefix.length..-1] if file.start_with?(prefix)
      file
    end

    def load_rule(rule, file, controls, groups)
      id = Inspec::Rule.rule_id(rule)
      controls[id] = {
        title: rule.title,
        desc: rule.desc,
        impact: rule.impact,
        refs: rule.ref,
        tags: rule.tag,
        checks: Inspec::Rule.checks(rule),
        code: rule.instance_variable_get(:@__code),
        source_location: rule.instance_variable_get(:@__source_location),
      }

      groups[file] ||= {
        title: rule.instance_variable_get(:@__group_title),
        controls: [],
      }
      groups[file][:controls].push(id)
    end

    def load_dependencies
      cwd = File.directory?(@target) ? @target : nil
      res = Inspec::Dependencies.new(cwd, nil)
      res.vendor(metadata.dependencies)
      res
    end
  end
end
