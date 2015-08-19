module Agents
  class EventFormattingAgent < Agent
    cannot_be_scheduled!

    description <<-MD
      The Event Formatting Agent allows you to format incoming Events, adding new fields as needed.

      For example, here is a possible Event:

          {
            "high": {
              "celsius": "18",
              "fahreinheit": "64"
            },
            "date": {
              "epoch": "1357959600",
              "pretty": "10:00 PM EST on January 11, 2013"
            },
            "conditions": "Rain showers",
            "data": "This is some data"
          }

      You may want to send this event to another Agent, for example a Twilio Agent, which expects a `message` key.
      You can use an Event Formatting Agent's `instructions` setting to do this in the following way:

          "instructions": {
            "message": "Today's conditions look like {{conditions}} with a high temperature of {{high.celsius}} degrees Celsius.",
            "subject": "{{data}}",
            "created_at": "{{created_at}}"
          }

      Names here like `conditions`, `high` and `data` refer to the corresponding values in the Event hash.

      The special key `created_at` refers to the timestamp of the Event, which can be reformatted by the `date` filter, like `{{created_at | date:"at %I:%M %p" }}`.

      The upstream agent of each received event is accessible via the key `agent`, which has the following attributes: #{''.tap { |s| s << AgentDrop.instance_methods(false).map { |m| "`#{m}`" }.join(', ') }}.

      Have a look at the [Wiki](https://github.com/cantino/huginn/wiki/Formatting-Events-using-Liquid) to learn more about liquid templating.

      Events generated by this possible Event Formatting Agent will look like:

          {
            "message": "Today's conditions look like Rain showers with a high temperature of 18 degrees Celsius.",
            "subject": "This is some data"
          }

      In `matchers` setting you can perform regular expression matching against contents of events and expand the match data for use in `instructions` setting.  Here is an example:

          {
            "matchers": [
              {
                "path": "{{date.pretty}}",
                "regexp": "\\A(?<time>\\d\\d:\\d\\d [AP]M [A-Z]+)",
                "to": "pretty_date"
              }
            ]
          }

      This virtually merges the following hash into the original event hash:

          "pretty_date": {
            "time": "10:00 PM EST",
            "0": "10:00 PM EST on January 11, 2013"
            "1": "10:00 PM EST"
          }

      So you can use it in `instructions` like this:

          "instructions": {
            "message": "Today's conditions look like {{conditions}} with a high temperature of {{high.celsius}} degrees Celsius according to the forecast at {{pretty_date.time}}.",
            "subject": "{{data}}"
          }

      If you want to retain original contents of events and only add new keys, then set `mode` to `merge`, otherwise set it to `clean`.

      To CGI escape output (for example when creating a link), use the Liquid `uri_escape` filter, like so:

          {
            "message": "A peak was on Twitter in {{group_by}}.  Search: https://twitter.com/search?q={{group_by | uri_escape}}"
          }
    MD

    event_description do
      "Events will have the following fields%s:\n\n    %s" % [
        case options['mode'].to_s
        when 'merged'
          ', merged with the original contents'
        when /\{/
          ', conditionally merged with the original contents'
        end,
        Utils.pretty_print(Hash[options['instructions'].keys.map { |key|
          [key, "..."]
        }])
      ]
    end

    after_save :clear_matchers

    def validate_options
      errors.add(:base, "instructions and mode need to be present.") unless options['instructions'].present? && options['mode'].present?

      validate_matchers
    end

    def default_options
      {
        'instructions' => {
          'message' =>  "You received a text {{text}} from {{fields.from}}",
          'agent' => "{{agent.type}}",
          'some_other_field' => "Looks like the weather is going to be {{fields.weather}}"
        },
        'matchers' => [],
        'mode' => "clean",
      }
    end

    def working?
      !recent_error_logs?
    end

    def receive(incoming_events)
      incoming_events.each do |event|
        interpolate_with(event) do
          interpolation_context.merge(perform_matching(event.payload))
          formatted_event = interpolated['mode'].to_s == "merge" ? event.payload.dup : {}
          formatted_event.merge! interpolated['instructions']
          create_event :payload => formatted_event
        end
      end
    end

    private

    def validate_matchers
      matchers = options['matchers'] or return

      unless matchers.is_a?(Array)
        errors.add(:base, "matchers must be an array if present")
        return
      end

      matchers.each do |matcher|
        unless matcher.is_a?(Hash)
          errors.add(:base, "each matcher must be a hash")
          next
        end

        regexp, path, to = matcher.values_at(*%w[regexp path to])

        if regexp.present?
          begin
            Regexp.new(regexp)
          rescue
            errors.add(:base, "bad regexp found in matchers: #{regexp}")
          end
        else
          errors.add(:base, "regexp is mandatory for a matcher and must be a string")
        end

        errors.add(:base, "path is mandatory for a matcher and must be a string") if !path.present?

        errors.add(:base, "to must be a string if present in a matcher") if to.present? && !to.is_a?(String)
      end
    end

    def perform_matching(payload)
      matchers.inject(payload.dup) { |hash, matcher|
        matcher[hash]
      }
    end

    def matchers
      @matchers ||=
        if matchers = options['matchers']
          matchers.map { |matcher|
            regexp, path, to = matcher.values_at(*%w[regexp path to])
            re = Regexp.new(regexp)
            proc { |hash|
              mhash = {}
              value = interpolate_string(path, hash)
              if value.is_a?(String) && (m = re.match(value))
                m.to_a.each_with_index { |s, i|
                  mhash[i.to_s] = s
                }
                m.names.each do |name|
                  mhash[name] = m[name]
                end if m.respond_to?(:names)
              end
              if to
                case value = hash[to]
                when Hash
                  value.update(mhash)
                else
                  hash[to] = mhash
                end
              else
                hash.update(mhash)
              end
              hash
            }
          }
        else
          []
        end
    end

    def clear_matchers
      @matchers = nil
    end
  end
end
