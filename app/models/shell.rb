class InvalidSelectorException < RuntimeError
end
class InvalidOperatorException < RuntimeError
end
class InvalidOptionException < RuntimeError
end

class Shell

  ALLOWED_SELECTORS = %w(all stream streams)
  ALLOWED_OPERATORS = %w(count find distinct)
  ALLOWED_CONDITIONALS = %w(>= <= > < = !=)
  ALLOWED_OPTIONS = %w(limit offset query)

  attr_reader :command, :selector, :operator, :operator_options, :stream_narrows, :modifiers, :result, :mongo_selector

  def initialize(cmd)
    @command = cmd

    parse
  end

  def compute
    case @operator
      when "count" then perform_count
      when "find" then perform_find
      when "distinct" then perform_distinct
      else raise InvalidOperatorException
    end

    @mongo_selector = criteria.selector

    return {
      :operation => @operator,
      :result => @result,
      :operator_options => @operator_options,
      :mongo_selector => @mongo_selector
    }
  end

  private
  def parse
    parse_selector
    parse_operator
    parse_operator_options
    parse modifiers
    
    validate

    if selector == "stream" or selector == "streams"
      parse_stream_narrows
    end

  end

  def parse_selector
    return @selector = @command.scan(/^(.+?)(\.|\()/)[0][0]
  end

  def parse_operator
    return @operator = @command.scan(/\.(.+?)\(/)[0][0]
  end

  def parse_stream_narrows
    string = @command.scan(/^streams?\((.+?)\)/)[0][0]
    streams = string.split(",")

    parsed = Array.new
    streams.each do |stream|
      parsed << stream.strip
    end

    @stream_narrows = parsed
  end

  def parse_operator_options
    string = @command.scan(/\.(#{ALLOWED_OPERATORS.join('|')})\((.+)\)/)

    if string.blank?
      return Array.new
    end

    string = string[0][1]
    singles = string.split(",")
    parsed = Hash.new
    singles.each do |single|
      key = single.scan(/^(.+?)(\s|#{ALLOWED_CONDITIONALS.join('|')})/)[0][0].strip
      p_value = single.scan(/(#{ALLOWED_CONDITIONALS.join('|')})(.+)$/)
      value = { :value => typify_value(p_value[0][1].strip), :condition => p_value[0][0].strip }

      # Avoid overwriting of same keys. Exampke (_http_return_code >= 200, _http_return_code < 300)
      if parsed[key].blank?
        # No double assignment.
        parsed[key] = value
      else
        if parsed[key].is_a?(Array)
          parsed[key] << value
        else
          parsed[key] = [ parsed[key], value ]
        end
      end
    end

    @operator_options = parsed
  rescue => e
    Rails.logger.error "Could not parse operator options: #{e.message + e.backtrace.join("\n")}"
    raise InvalidOperatorException
  end

  def parse_modifiers # \.(limit|offset|query)\((.+?)\)
  
  end

  def typify_value(option)
    if option.start_with?('"') and option.end_with?('"')
      return option[1..-2]
    elsif option.start_with?("/") and option.end_with?("/")
      # lol, regex
      return /#{option[1..-2]}/
    else
      return option.to_i
    end
  rescue
    return String.new
  end

  def mongofy_options(options)
    criteria = Hash.new
    unless options.blank?
      options.each do |k,v|
        criteria[k] = mongo_conditionize(v)
      end
    end

    return criteria
  end

  def mongofy_stream_narrows(streams)
    return nil if streams.blank?

    criteria = Hash.new

    if streams.count == 1
      criteria = { :streams => BSON::ObjectId(streams[0]) }
    else
      stream_arr = Array.new
      streams.each do |stream|
        stream_arr << BSON::ObjectId(stream)
      end
      
      criteria = { :streams => { "$in" => stream_arr } }
    end

    return criteria
  end

  def mongo_conditionize(v)
    if v.is_a?(Hash)
      raise InvalidOptionException if !ALLOWED_CONDITIONALS.include?(v[:condition])
      
      if v[:condition] == "="
        return v[:value] # No special mongo treatment for = needed.
      else
        return { map_mongo_condition(v[:condition]) => v[:value] }
      end
    elsif v.is_a?(Array)
      conditions = Hash.new
      v.each do |condition|
        # Return if there is a = condition as this can't be combined with other conditions.
        if condition[:condition] == "="
          return condition[:value] # No special mongo treatment for = needed.
        elsif condition[:condition] == "!=" # This needs special treatment with $nin mongo operator.
          conditions["$nin"] = Array.new if conditions["$nin"].blank?
          conditions["$nin"] << condition[:value]
        else
          conditions[map_mongo_condition(condition[:condition])] = condition[:value]
        end
      end

      return conditions
    else
      raise InvalidOptionException
    end
  end

  def map_mongo_condition(c)
    case c
      when ">=" then return "$gte"
      when "<=" then return "$lte"
      when ">" then return "$gt"
      when "<" then return "$lt"
      when "!=" then return "$ne"
      else raise InvalidOptionException
    end
  end

  def validate
    raise InvalidSelectorException unless ALLOWED_SELECTORS.include?(@selector)
    raise InvalidOperatorException unless ALLOWED_OPERATORS.include?(@operator)
  end

  def criteria
    Message.not_deleted.where(mongofy_options(@operator_options)).where(mongofy_stream_narrows(@stream_narrows))
  end

  def perform_count
    @result = criteria.count
  end

  def perform_find
    @result = criteria.all
  end

end
