require 'journey/router/utils'
require 'journey/router/strexp'

before = $-w
$-w = false
require 'journey/definition/parser'
$-w = before

require 'journey/route'
require 'journey/path/pattern'

require 'journey/backwards' # backwards compat stuff

module Journey
  class Router
    class RoutingError < ::StandardError
    end

    VERSION = '1.0.0'

    class NullReq # :nodoc:
      def self.new env; env; end
    end

    attr_reader :routes, :named_routes, :request_class

    def initialize options
      @options       = options
      @routes        = []
      @named_routes  = {}
      @params_key    = options[:parameters_key]
      @request_class = options[:request_class] || NullReq
    end

    def add_route app, conditions, defaults, name = nil
      path = conditions[:path_info]
      route = Route.new(app, path, conditions, defaults)
      routes << route
      named_routes[name] = route if name
      route
    end

    def generate key, name, options, recall = {}, parameterize = nil
      route          = named_routes[name] || match_route(recall.merge(options))

      segment_values = options.dup.keep_if { |_,v| v }

      # Find a list of url parts that were made available in the options hash.
      provided_parts = route.parts.reverse.drop_while { |part|
        !segment_values.key?(part)
      } | route.required_parts

      # Pull the parts from the options hash or the "recall" hash.
      route_values = provided_parts.map { |part|
        [part, segment_values[part] || recall[part]]
      }

      parameterized_parts = route_values

      if parameterize
        parameterized_parts = route_values.map { |k,v|
          [k, parameterize[:parameterize].call(k, v)]
        }
      end

      parameterized_parts.keep_if { |_,v| v  }
      parameterized_parts = Hash[parameterized_parts]

      verify_required_parts!(route, parameterized_parts)

      z = Hash[options.to_a - route_values]
      z.delete :controller
      z.delete :action

      [route.format(parameterized_parts), z]
    end

    def call env
      match_data, route = route_for(env)

      return [404, {'X-Cascade' => 'pass'}, ['Not Found']] unless route

      env[@params_key] = match_data

      route.app.call(env)
    end

    def recognize req
      match_data, route = route_for req.env
      yield(route, nil, match_data) if route
    end

    private
    def match_route options
      routes.sort_by { |r| r.score options }.last
    end

    def route_for env
      match_data = nil
      addr       = env['REMOTE_ADDR']
      req        = request_class.new env

      route = routes.find do |r|
        next unless r.verb === env['REQUEST_METHOD']
        next if addr && !r.ip === addr

        next unless r.constraints.all? { |k,v|
          v === req.send(k)
        }

        match_data = r.path.match env['PATH_INFO']
      end

      return unless route

      unless match_data.post_match.empty?
        env['SCRIPT_NAME'] = match_data.to_s
        env['PATH_INFO']   = match_data.post_match
      end

      match_names = match_data.names.map { |n| n.to_sym }
      info = Hash[match_names.zip(match_data.captures).find_all { |_,y| y }]
      [route.extras.merge(info), route]
    end

    def verify_required_parts! route, parts
      tests = route.path.requirements
      raise RoutingError unless (tests.keys & route.required_parts).all? { |key|
        /\A#{tests[key]}\Z/ === parts[key]
      }
    end
  end
end
