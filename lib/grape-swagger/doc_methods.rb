require 'grape-swagger/doc_methods/status_codes'

require 'grape-swagger/doc_methods/produces_consumes'
require 'grape-swagger/doc_methods/data_type'
require 'grape-swagger/doc_methods/extensions'
require 'grape-swagger/doc_methods/operation_id'
require 'grape-swagger/doc_methods/optional_object'
require 'grape-swagger/doc_methods/path_string'
require 'grape-swagger/doc_methods/tag_name_description'
require 'grape-swagger/doc_methods/parse_params'
require 'grape-swagger/doc_methods/move_params'
require 'grape-swagger/doc_methods/headers'

module GrapeSwagger
  module DocMethods
    def name
      @@class_name
    end

    def as_markdown(description)
      description && @@markdown ? @@markdown.as_markdown(strip_heredoc(description)) : description
    end

    def parse_params(params, path, method)
      params ||= []

      parsed_array_params = parse_array_params(params)

      non_nested_parent_params = get_non_nested_params(parsed_array_params)

      non_nested_parent_params.map do |param, value|
        items = {}

        raw_data_type = value[:type] if value.is_a?(Hash)
        raw_data_type ||= 'string'
        data_type     = case raw_data_type.to_s
                        when 'Hash'
                          'object'
                        when 'Rack::Multipart::UploadedFile'
                          'File'
                        when 'Virtus::Attribute::Boolean'
                          'boolean'
                        when 'Boolean', 'Date', 'Integer', 'String', 'Float'
                          raw_data_type.to_s.downcase
                        when 'BigDecimal'
                          'long'
                        when 'DateTime'
                          'dateTime'
                        when 'Numeric'
                          'double'
                        when 'Symbol'
                          'string'
                        else
                          @@documentation_class.parse_entity_name(raw_data_type)
                        end

        additional_documentation = value.is_a?(Hash) ? value[:documentation] : nil

        if additional_documentation && value.is_a?(Hash)
          value = additional_documentation.merge(value)
        end

        next if value.is_a?(Hash) && value[:documentation] && value[:documentation].try(:[], :hide)

        description          = value.is_a?(Hash) ? value[:desc] || value[:description] : ''
        required             = value.is_a?(Hash) ? !!value[:required] : false
        default_value        = value.is_a?(Hash) ? value[:default] : nil
        example              = value.is_a?(Hash) ? value[:example] : nil
        is_array             = value.is_a?(Hash) ? (value[:is_array] || false) : false
        values               = value.is_a?(Hash) ? value[:values] : nil
        enum_or_range_values = parse_enum_or_range_values(values)

        if value.is_a?(Hash) && value.key?(:documentation) && value[:documentation].key?(:param_type)
          param_type  = value[:documentation][:param_type]
          if is_array
            items     = { '$ref' => data_type }
            data_type = 'array'
          end
        else
          param_type  = case
                        when path.include?(":#{param}")
                          'path'
                        when %w(POST PUT PATCH).include?(method)
                          if is_primitive?(data_type)
                            'form'
                          else
                            'body'
                          end
                        else
                          'query'
                        end
        end
        name          = (value.is_a?(Hash) && value[:full_name]) || param

        parsed_params = {
          paramType:     param_type,
          name:          name,
          description:   as_markdown(description),
          type:          data_type,
          required:      required,
          allowMultiple: is_array
        }

        if PRIMITIVE_MAPPINGS.key?(data_type)
          parsed_params[:type], parsed_params[:format] = PRIMITIVE_MAPPINGS[data_type]
        end

        parsed_params[:items]  = items   if items.present?

        parsed_params[:defaultValue] = example if example
        if default_value && example.blank?
          parsed_params[:defaultValue] = default_value
        end

        parsed_params.merge!(enum_or_range_values) if enum_or_range_values
        parsed_params
      end.compact
    end

    def content_types_for(target_class)
      content_types = (target_class.content_types || {}).values

      if content_types.empty?
        formats       = [target_class.format, target_class.default_format].compact.uniq
        formats       = Grape::Formatter::Base.formatters({}).keys if formats.empty?
        content_types = Grape::ContentTypes::CONTENT_TYPES.select { |content_type, _mime_type| formats.include? content_type }.values
      end

      content_types.uniq
    end

    def parse_info(info)
      {
        contact:            info[:contact],
        description:        as_markdown(info[:description]),
        license:            info[:license],
        licenseUrl:         info[:license_url],
        termsOfServiceUrl:  info[:terms_of_service_url],
        title:              info[:title]
      }.delete_if { |_, value| value.blank? }
    end

    def parse_header_params(params)
      params ||= []

      params.map do |param, value|
        data_type     = 'string'
        description   = value.is_a?(Hash) ? value[:description] : ''
        required      = value.is_a?(Hash) ? !!value[:required] : false
        default_value = value.is_a?(Hash) ? value[:default] : nil
        param_type    = 'header'

        parsed_params = {
          paramType:    param_type,
          name:         param,
          description:  as_markdown(description),
          type:         data_type,
          required:     required
        }

        parsed_params.merge!(defaultValue: default_value) if default_value

        parsed_params
      end
    end

    def parse_path(path, version)
      # adapt format to swagger format
      parsed_path = path.gsub('(.:format)', @@hide_format ? '' : '.{format}')
      # This is attempting to emulate the behavior of
      # Rack::Mount::Strexp. We cannot use Strexp directly because
      # all it does is generate regular expressions for parsing URLs.
      # TODO: Implement a Racc tokenizer to properly generate the
      # parsed path.
      parsed_path = parsed_path.gsub(/:([a-zA-Z_]\w*)/, '{\1}')
      # add the version
      version ? parsed_path.gsub('{version}', version) : parsed_path
    end

    def parse_entity_name(model)
      if model.respond_to?(:entity_name)
        model.entity_name
      else
        name = model.to_s
        entity_parts = name.split('::')
        entity_parts.reject! { |p| p == 'Entity' || p == 'Entities' }
        entity_parts.join('::')
      end
    end

    def parse_entity_models(models)
      result = {}
      models.each do |model|
        name       = (model.instance_variable_get(:@root) || parse_entity_name(model))
        properties = {}
        required   = []

        model.documentation.each do |property_name, property_info|
          p = property_info.dup

          exposed_name = p.delete(:alias_for) || property_name

          next unless exposure = model.exposures[exposed_name]

          required << property_name.to_s if p.delete(:required)

          type = if p[:type]
                   p.delete(:type)
                 else
                   parse_entity_name(exposure[:using])
                 end

          if p.delete(:is_array)
            p[:items] = generate_typeref(type)
            p[:type] = 'array'
          else
            p.merge! generate_typeref(type)
          end

          # rename Grape Entity's "desc" to "description"
          property_description = p.delete(:desc)
          p[:description] = property_description if property_description

          # rename Grape's 'values' to 'enum'
          select_values = p.delete(:values)
          if select_values
            select_values = select_values.call if select_values.is_a?(Proc)
            p[:enum] = select_values
          end

          if PRIMITIVE_MAPPINGS.key?(p['type'])
            p['type'], p['format'] = PRIMITIVE_MAPPINGS[p['type']]
          end

          properties[property_name] = p
        end

        result[name] = {
          id:         name,
          properties: properties
        }
        result[name].merge!(required: required) unless required.empty?
      end

      result
    end

    def models_with_included_presenters(models)
      all_models = models

      models.each do |model|
        # get model references from exposures with a documentation
        nested_models = model.exposures.map do |_, config|
          if config.key?(:documentation)
            model = config[:using]
            model.respond_to?(:constantize) ? model.constantize : model
          end
        end.compact

        # get all nested models recursively
        additional_models = nested_models.map do |nested_model|
          models_with_included_presenters([nested_model])
        end.flatten

        all_models += additional_models
      end

      all_models
    end

    def is_primitive?(type)
      %w(object integer long float double string byte boolean date dateTime).include? type
    end

    def generate_typeref(type)
      type_s = type.to_s.sub(/^[A-Z]/) { |f| f.downcase }
      if is_primitive? type_s
        { 'type' => type_s }
      else
        { '$ref' => parse_entity_name(type) }
      end
    end

    def parse_http_codes(codes, models)
      codes ||= {}
      codes.map do |k, v, m|
        models << m if m
        http_code_hash = {
          code: k,
          message: v
        }
        http_code_hash[:responseModel] = parse_entity_name(m) if m
        http_code_hash
      end
    end

    def strip_heredoc(string)
      indent = string.scan(/^[ \t]*(?=\S)/).min.try(:size) || 0
      string.gsub(/^[ \t]{#{indent}}/, '')
    end

    def parse_base_path(base_path, request)
      if base_path.is_a?(Proc)
        base_path.call(request)
      elsif base_path.is_a?(String)
        URI(base_path).relative? ? URI.join(request.base_url, base_path).to_s : base_path
      else
        request.base_url
      end
    end

    def hide_documentation_path
      @@hide_documentation_path
    end

    def mount_path
      @@mount_path
    end

    def setup(options)
      options = defaults.merge(options)

      # options could be set on #add_swagger_documentation call,
      # for available options see #defaults
      target_class     = options[:target_class]
      api_doc          = options[:api_documentation].dup
      specific_api_doc = options[:specific_api_documentation].dup

      class_variables_from(options)

      [:format, :default_format, :default_error_formatter].each do |method|
        send(method, options[:format])
      end if options[:format]
      # getting of the whole swagger2.0 spec file
      desc api_doc.delete(:desc), api_doc
      get mount_path do
        header['Access-Control-Allow-Origin']   = '*'
        header['Access-Control-Request-Method'] = '*'

        output = swagger_object(
          target_class,
          request,
          options
        )

        target_routes        = target_class.combined_namespace_routes
        paths, definitions   = path_and_definition_objects(target_routes, options)
        output[:paths]       = paths unless paths.blank?
        output[:definitions] = definitions unless definitions.blank?

        output
      end

      # getting of a specific/named route of the swagger2.0 spec file
      desc specific_api_doc.delete(:desc), { params:
        specific_api_doc.delete(:params) || {} }.merge(specific_api_doc)
      params do
        requires :name, type: String, desc: 'Resource name of mounted API'
        optional :locale, type: Symbol, desc: 'Locale of API documentation'
      end
      get "#{mount_path}/:name" do
        I18n.locale = params[:locale] || I18n.default_locale

        combined_routes = target_class.combined_namespace_routes[params[:name]]
        error!({ error: 'named resource not exist' }, 400) if combined_routes.nil?

        output = swagger_object(
          target_class,
          request,
          options
        )

        target_routes        = { params[:name] => combined_routes }
        paths, definitions   = path_and_definition_objects(target_routes, options)
        output[:paths]       = paths unless paths.blank?
        output[:definitions] = definitions unless definitions.blank?

        output
      end
    end

    def defaults
      {
        info: {},
        models: [],
        doc_version: '0.0.1',
        target_class: nil,
        mount_path: '/swagger_doc',
        host: nil,
        base_path: nil,
        add_base_path: false,
        add_version: true,
        markdown: false,
        hide_documentation_path: true,
        format: :json,
        authorizations: nil,
        api_documentation: { desc: 'Swagger compatible API description' },
        specific_api_documentation: { desc: 'Swagger compatible API description for specific API' }
      }
    end

    def class_variables_from(options)
      @@mount_path              = options[:mount_path]
      @@class_name              = options[:class_name] || options[:mount_path].delete('/')
      @@hide_documentation_path = options[:hide_documentation_path]
    end
  end
end
