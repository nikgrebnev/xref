# frozen_string_literal: true

module Xref
  # Facts only a running application knows.
  #
  # Routes are not parsed out of `config/routes.rb` and models are not guessed
  # from file names: both are asked of the framework itself after `eager_load!`.
  # Parsing 889 lines of routes with regular expressions would produce a third
  # source of truth, drifting from the real one.
  module RailsFacts
    class << self
      # THIS IS THE ONE COLLECTION THAT GENUINELY NEEDS A LOADED APPLICATION, and
      # a standalone installation does not have one. Saying so is the whole fix:
      # previously the task died with `uninitialized constant Rails`, which reads
      # as a broken tool rather than as a missing prerequisite. Everything else
      # the index does works without an application, and the index says what it
      # loses by this one being absent — no model map, so ORM accesses are not
      # bound to tables.
      def load!
        unless defined?(Rails) && Rails.respond_to?(:application)
          raise Error, 'факты приложения нужно собирать ИЗ приложения: зовите через ' \
                       'bin/rails xref:app. Без них индекс работает, но обращения ' \
                       'через ORM не привязаны к таблицам, и отчёт это говорит'
        end

        Rails.application.eager_load!
      end

      # => [{class_name:, table_name:, path:, primary_key:}]
      def models
        ActiveRecord::Base.descendants.filter_map do |model|
          next if model.abstract_class? || model.name.blank?

          { class_name: model.name,
            table_name: safely { model.table_name },
            path: source_path(model.name),
            # A key can be composite and then arrives as an array.
            primary_key: safely { Array(model.primary_key).join(',') },
            # Models of other subsystems live in other databases. What tells
            # them apart is not `connection_db_config` (for some of them it
            # reports our database until ENV is configured) but the nearest
            # abstract ancestor: ours sit under ApplicationRecord, the rest
            # under their own.
            base: safely { abstract_base(model) },
            database: safely { model.connection_db_config&.database } }
        end
      end

      # => [{class_name:, name:, macro:, target:, foreign_key:}]
      def associations
        ActiveRecord::Base.descendants.flat_map do |model|
          next [] if model.abstract_class? || model.name.blank?

          (safely { model.reflect_on_all_associations } || []).map do |reflection|
            { class_name: model.name,
              name: reflection.name.to_s,
              macro: reflection.macro.to_s,
              target: safely { reflection.klass&.name },
              foreign_key: safely { reflection.foreign_key.to_s } }
          end
        end
      end

      # => [{verb:, path:, controller:, action:, route_name:}]
      def routes
        Rails.application.routes.routes.map do |route|
          defaults = route.defaults || {}
          controller = defaults[:controller].to_s
          { verb: route.verb.to_s.gsub(%r{[$^/]}, ''),
            path: route.path.spec.to_s.sub(/\(\.:format\)\z/, ''),
            controller: controller,
            action: defaults[:action].to_s,
            # The class name is assembled here rather than in SQL: from
            # `some_namespace/hbase_failures` SQL cannot restore the namespace.
            controller_class: controller.present? ? "#{controller.camelize}Controller" : nil,
            route_name: route.name }
        end
      end

      # Scheduled jobs together with their per-environment restriction.
      #
      # This is the one place where the code itself says where it runs:
      # a place key of `[2]` means "in the first data centre only". Without it "the
      # table is absent on that environment" looks like a defect where the job
      # does not even start.
      #
      # The name of the registry and the name of the key are CONFIGURATION
      # (`idioms.cron_registry`, `idioms.cron_place_key`): the engine used to know
      # one particular application's constant by heart, and a name from one tree
      # baked into the parser is exactly the unportability of III.4.
      #
      # => [{job_key:, class_name:, cron:, places: [..], path:}]
      def jobs
        schedule = cron_schedule
        return [] if schedule.nil?

        place_key = (Xref.idioms[:cron_place_key] || 'place').to_sym
        schedule.flat_map do |key, entry|
          variants = entry[:variants] || [entry]
          variants.map do |variant|
            { job_key: key.to_s,
              class_name: variant[:class].to_s,
              cron: variant[:cron].to_s,
              places: Array(variant[place_key]).map(&:to_s),
              path: source_path(variant[:class].to_s) }
          end
        end
      end

      # A missing registry is an absence, not an error: a project may have no
      # scheduled jobs at all, and a name in the configuration may be stale.
      def cron_schedule
        name = Xref.idioms[:cron_registry].to_s
        return nil if name.empty?

        Object.const_get(name)
      rescue NameError
        nil
      end

      # The "constant -> file" map from the autoloader itself: 1,039 entries.
      # Deriving it from paths is not possible — the project has namespaces of
      # its own.
      #
      # => [{constant:, path:}]
      def constants
        loader = Rails.autoloaders.main
        return [] unless loader.respond_to?(:all_expected_cpaths)

        loader.all_expected_cpaths.filter_map do |path, constant|
          next unless path.end_with?('.rb')
          next if constant.blank? || constant == 'Object'

          { constant: constant, path: path.sub("#{Rails.root}/", '') }
        end
      end

      # => [{class_name:, path:, actions: [..]}]
      def controllers
        ActionController::Base.descendants.filter_map do |controller|
          next if controller.name.blank?

          { class_name: controller.name,
            path: source_path(controller.name),
            actions: (safely { controller.action_methods.to_a.sort } || []) }
        end
      end

      private

      def abstract_base(model)
        model.ancestors.find do |ancestor|
          ancestor.is_a?(Class) && ancestor != model &&
            ancestor.respond_to?(:abstract_class?) && ancestor.abstract_class?
        end&.name
      end

      def source_path(class_name)
        location = Object.const_source_location(class_name)&.first
        return nil if location.blank?

        location.sub("#{Rails.root}/", '')
      rescue StandardError
        nil
      end

      # A model can break on anything: a missing table, a broken association,
      # someone else's connection. No reason to lose the whole snapshot over one
      # field.
      def safely
        yield
      rescue StandardError
        nil
      end
    end
  end
end
