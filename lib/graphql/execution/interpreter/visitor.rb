# frozen_string_literal: true

module GraphQL
  module Execution
    class Interpreter
      # The visitor itself is stateless,
      # it delegates state to the `trace`
      #
      # It sets up a lot of context with `push` and `pop`
      # to keep noise out of the Ruby backtrace.
      #
      # I think it would be even better if we could somehow make
      # `continue_field` not recursive. "Trampolining" it somehow.
      class Visitor
        def visit(trace)
          root_operation = trace.query.selected_operation
          root_type = trace.schema.root_type_for_operation(root_operation.operation_type || "query")
          root_type = root_type.metadata[:type_class]
          object_proxy = root_type.authorized_new(trace.query.root_value, trace.query.context)

          trace.types.push(root_type)
          trace.objects.push(object_proxy)
          evaluate_selections(root_operation.selections, trace)
          trace.types.pop
          trace.objects.pop
        end

        def gather_selections(selections, trace, selections_by_name)
          selections.each do |node|
            case node
            when GraphQL::Language::Nodes::Field
              if passes_skip_and_include?(trace, node)
                response_key = node.alias || node.name
                s = selections_by_name[response_key] ||= []
                s << node
              end
            when GraphQL::Language::Nodes::InlineFragment
              if passes_skip_and_include?(trace, node)
                include_fragmment = if node.type
                  type_defn = trace.schema.types[node.type.name]
                  type_defn = type_defn.metadata[:type_class]
                  possible_types = trace.schema.possible_types(type_defn).map { |t| t.metadata[:type_class] }
                  owner_type = resolve_if_late_bound_type(trace.types.last, trace)
                  possible_types.include?(owner_type)
                else
                  true
                end
                if include_fragmment
                  gather_selections(node.selections, trace, selections_by_name)
                end
              end
            when GraphQL::Language::Nodes::FragmentSpread
              if passes_skip_and_include?(trace, node)
                fragment_def = trace.query.fragments[node.name]
                type_defn = trace.schema.types[fragment_def.type.name]
                type_defn = type_defn.metadata[:type_class]
                possible_types = trace.schema.possible_types(type_defn).map { |t| t.metadata[:type_class] }
                owner_type = resolve_if_late_bound_type(trace.types.last, trace)
                if possible_types.include?(owner_type)
                  gather_selections(fragment_def.selections, trace, selections_by_name)
                end
              end
            else
              raise "Invariant: unexpected selection class: #{node.class}"
            end
          end
        end

        def evaluate_selections(selections, trace)
          selections_by_name = {}
          gather_selections(selections, trace, selections_by_name)
          selections_by_name.each do |result_name, fields|
            owner_type = trace.types.last
            owner_type = resolve_if_late_bound_type(owner_type, trace)
            ast_node = fields.first
            field_name = ast_node.name
            field_defn = owner_type.fields[field_name]
            is_introspection = false
            if field_defn.nil?
              field_defn = if owner_type == trace.schema.query.metadata[:type_class] && (entry_point_field = trace.schema.introspection_system.entry_point(name: field_name))
                is_introspection = true
                entry_point_field.metadata[:type_class]
              elsif (dynamic_field = trace.schema.introspection_system.dynamic_field(name: field_name))
                is_introspection = true
                dynamic_field.metadata[:type_class]
              else
                raise "Invariant: no field for #{owner_type}.#{field_name}"
              end
            end

            # TODO: this support is required for introspection types.
            if !field_defn.respond_to?(:extras)
              field_defn = field_defn.metadata[:type_class]
            end

            return_type = resolve_if_late_bound_type(field_defn.type, trace)

            # Setup trace context
            trace.fields.push(field_defn)
            trace.path.push(result_name)
            trace.types.push(return_type)
            # TODO this seems janky, but we need to know
            # the field's return type at this path in order
            # to propagate `null`
            trace.set_type_at_path(return_type)
            trace.query.trace("execute_field", {trace: trace}) do
              object = trace.objects.last

              if is_introspection
                object = field_defn.owner.authorized_new(object, trace.context)
              end

              kwarg_arguments = trace.arguments(field_defn, ast_node)
              # TODO: very shifty that these cached Hashes are being modified
              if field_defn.extras.include?(:ast_node)
                kwarg_arguments[:ast_node] = ast_node
              end
              if field_defn.extras.include?(:execution_errors)
                kwarg_arguments[:execution_errors] = ExecutionErrors.new(trace.context, ast_node, trace.path.dup)
              end

              app_result = field_defn.resolve_field_2(object, kwarg_arguments, trace.context)

              trace.after_lazy(app_result) do |inner_trace, inner_result|
                if continue_value(inner_result, field_defn, return_type, ast_node, inner_trace)
                  # TODO will this be a perf issue for scalar fields?
                  next_selections = fields.map(&:selections).inject(&:+)
                  continue_field(inner_result, field_defn, return_type, ast_node, inner_trace, next_selections)
                end
              end
            end
            # Teardown trace context,
            # if the trace needs any of it, it will have been capture via `Trace#dup`
            trace.fields.pop
            trace.path.pop
            trace.types.pop
          end
        end

        def continue_value(value, field, as_type, ast_node, trace)
          if value.nil? || value.is_a?(GraphQL::ExecutionError)
            if value.nil?
              if as_type.non_null?
                err = GraphQL::InvalidNullError.new(field.owner, field, value)
                trace.write(err, propagating_nil: true)
              else
                trace.write(nil)
              end
            else
              value.path ||= trace.path.dup
              value.ast_node ||= ast_node
              trace.write(value, propagating_nil: as_type.non_null?)
            end
            false
          elsif value.is_a?(Array) && value.all? { |v| v.is_a?(GraphQL::ExecutionError) }
            value.each do |v|
              v.path ||= trace.path.dup
              v.ast_node ||= ast_node
            end
            trace.write(value, propagating_nil: as_type.non_null?)
            false
          elsif GraphQL::Execution::Execute::SKIP == value
            false
          else
            true
          end
        end

        def continue_field(value, field, type, ast_node, trace, next_selections)
          type = resolve_if_late_bound_type(type, trace)

          case type.kind
          when TypeKinds::SCALAR, TypeKinds::ENUM
            r = type.coerce_result(value, trace.query.context)
            trace.write(r)
          when TypeKinds::UNION, TypeKinds::INTERFACE
            obj_type = trace.schema.resolve_type(type, value, trace.query.context)
            obj_type = obj_type.metadata[:type_class]
            trace.types.push(obj_type)
            continue_field(value, field, obj_type, ast_node, trace, next_selections)
            trace.types.pop
          when TypeKinds::OBJECT
            object_proxy = type.authorized_new(value, trace.query.context)
            trace.after_lazy(object_proxy) do |inner_trace, inner_object|
              if continue_value(inner_object, field, type, ast_node, inner_trace)
                inner_trace.write({})
                inner_trace.objects.push(inner_object)
                evaluate_selections(next_selections, inner_trace)
                inner_trace.objects.pop
              end
            end
          when TypeKinds::LIST
            trace.write([])
            inner_type = type.of_type
            value.each_with_index.each do |inner_value, idx|
              trace.path.push(idx)
              trace.types.push(inner_type)
              trace.set_type_at_path(inner_type)
              trace.after_lazy(inner_value) do |inner_trace, inner_inner_value|
                if continue_value(inner_inner_value, field, inner_type, ast_node, inner_trace)
                  continue_field(inner_inner_value, field, inner_type, ast_node, inner_trace, next_selections)
                end
              end
              trace.path.pop
              trace.types.pop
            end
          when TypeKinds::NON_NULL
            inner_type = type.of_type
            # Don't `set_type_at_path` because we want the static type,
            # we're going to use that to determine whether a `nil` should be propagated or not.
            trace.types.push(inner_type)
            continue_field(value, field, inner_type, ast_node, trace, next_selections)
            trace.types.pop
          else
            raise "Invariant: Unhandled type kind #{type.kind} (#{type})"
          end
        end

        def passes_skip_and_include?(trace, node)
          # TODO call out to directive here
          node.directives.each do |dir|
            dir_defn = trace.schema.directives.fetch(dir.name)
            if dir.name == "skip" && trace.arguments(dir_defn, dir)[:if] == true
              return false
            elsif dir.name == "include" && trace.arguments(dir_defn, dir)[:if] == false
              return false
            end
          end
          true
        end

        def resolve_if_late_bound_type(type, trace)
          if type.is_a?(GraphQL::Schema::LateBoundType)
            trace.query.warden.get_type(type.name).metadata[:type_class]
          else
            type
          end
        end
      end
    end
  end
end