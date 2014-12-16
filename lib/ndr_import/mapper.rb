# This module provides helper logic for mapping unified sources for import into the system
module UnifiedSources::Import::Mapper
  
  private
  
  # uses the mappings for this line to unpack the fixed width string
  # returning an array of the resulting columns
  def fixed_width_columns(line, line_mappings)
    unpack_patterns = line_mappings.map{ |c| c['unpack_pattern'] }.join
    line.unpack(unpack_patterns)
  end
  
  # the replace option can be used before any other mapping option
  def replace_before_mapping(original_value, field_mapping)
    if field_mapping.include?('replace') && original_value
      [field_mapping['replace']].flatten.each do |field_replacement|
        field_replacement.each do |pattern, replacement|
          original_value.gsub!(pattern, replacement)
        end
      end
    end  
  end
  
  # Returns the standard_mapping hash specified
  # Assumes mappping exists
  def standard_mapping(mapping_name,column_mapping)
    # SECURE: TVB Thu Aug  9 16:57:17 BST 2012 : RAILS_ROOT is constant and the relative path is hardcoded.
    # Therefore always the same file will be loaded.
    # Recommendation is to use SafeFile and SafePath - the idea is never to use File in the project, but only a proxy class SafeFile.
    @standard_mappings = YAML.load(File.open(Rails.root + "config/mappings/standard_mappings.yml")) unless @standard_mappings
    mapping = @standard_mappings[mapping_name]
    return nil if mapping.nil?
    if column_mapping['mappings']
      mapping['mappings'] = mapping['mappings'] + column_mapping.delete('mappings')
    end
    mapping.merge(column_mapping)
  end

  # This takes an array of raw values and their associated mappings and returns an attribute hash
  # It accepts a block to alter the raw value that is stored in the raw text (if necessary),
  # enabling it to work for different sources
  def mapped_line(line, line_mappings)
    attributes = {}
    rawtext = {}
    validate_line_mappings(line_mappings) 
    line.each_with_index do |raw_value, col|
      
      column_mapping = line_mappings[col]
      if column_mapping.nil?
        raise ArgumentError, "Line has too many columns (expected #{line_mappings.size} but got #{line.size})"
      end
      
      next if column_mapping['do_not_capture']
      
      if column_mapping['standard_mapping']
        column_mapping = standard_mapping(column_mapping['standard_mapping'],column_mapping)
      end
      field_mappings = column_mapping['mappings'] || []
      
      # Establish the rawtext column name we are to use for this column
      rawtext_column_name = (column_mapping['rawtext_name'] || column_mapping['column']).downcase
      
      # raw value casting can vary between sources, so we allow the caller to apply it here
      if respond_to?(:cast_raw_value)
        raw_value = cast_raw_value(rawtext_column_name, raw_value, column_mapping)
      end

      # Store the raw column value
      rawtext[rawtext_column_name] = raw_value
      
      field_mappings.each do |field_mapping|
        # create a duplicate of the raw value we can manipulate
        original_value = raw_value ? raw_value.dup : nil

        replace_before_mapping(original_value, field_mapping)
        value = mapped_value(original_value, field_mapping)

        field = field_mapping['field']

        # Assumes join is specified in first joined field
        joined = field_mapping['join'] ? true : false

        # Currently assuming already validated YAML, s.t. no fields have the
        # same priorities
        #
        # This has become really messy...
        unless value.blank? && !joined
          attributes[field] = {} unless attributes[field]
          attributes[field][:priority] = {} unless attributes[field][:priority]
          if field_mapping['order']
            attributes[field][field_mapping['order']] = value
            attributes[field][:join] = field_mapping['join'] if field_mapping['join']
            attributes[field][:compact] = field_mapping['compact'] if field_mapping.include?('compact')
          elsif field_mapping['priority']
            attributes[field][:priority][field_mapping['priority']] = value
          else
            # Check if already a mapped-to field, and assign default low
            # priority
            attributes[field][:priority][1] = value
            attributes[field][:value] = value
          end
        end
      end
    end
    
    # tidy up many to one field mappings
    # and one to many, for cross-populating
    attributes.each do |field, value|
      if value.include?(:join)
        join_string = value.delete(:join) || ','
        value.delete(:value)
        value.delete(:priority)
        if value.include?(:compact)
          compact = value.delete(:compact)
        else
          compact = true
        end
        t = value.sort.map { |part_order, part_value|
          part_value.blank? ? nil : part_value
        }
        if compact        
          attributes[field] = t.compact.join(join_string)
        else
          attributes[field] = t.join(join_string)
        end
      else
        attributes[field][:priority].reject!{ |k,v| v.blank? }
        attributes[field] = attributes[field][:priority].sort.first[1]
      end
    end
    
    attributes[:rawtext] = rawtext
    attributes
  end
  
  def mapped_value(original_value, field_mapping)
    if field_mapping.include?('format')
      begin
        value = original_value.blank? ? nil : original_value.to_date(field_mapping['format'])
      rescue ArgumentError => e
        e2 = ArgumentError.new("#{e.to_s} value #{original_value.inspect}")
        e2.set_backtrace(e.backtrace)
        raise e2
      end
    elsif field_mapping.include?('clean')
      value = original_value.blank? ? nil : original_value.clean(field_mapping['clean'])
    elsif field_mapping.include?('map')
      value = field_mapping['map'] ? field_mapping['map'][original_value] : nil
    elsif field_mapping.include?('match')
      # WARNING:TVB Thu Aug  9 17:09:25 BST 2012 field_mapping['match'] regexp may need to be escaped
      matches = Regexp.new(field_mapping['match']).match(original_value)
      value = matches[1].strip if matches && matches.size > 0
    elsif field_mapping.include?('daysafter')
      value = original_value.to_i.days.since(field_mapping['daysafter'].to_time).to_date
    else
      value = original_value.blank? ? nil :
        original_value.is_a?(String) ? original_value.strip : original_value
    end
  end

  # Check for duplicate priorities, check for nonexistent standard_mappings
  def validate_line_mappings(line_mappings)
    priority = {}
    line_mappings.each do |column_mapping|
      if column_mapping['standard_mapping']
        if standard_mapping(column_mapping['standard_mapping'],column_mapping).nil?
          raise "Standard mapping \"#{column_mapping['standard_mapping']}\" does not exist"
        end
      end
      field_mappings = column_mapping['mappings'] || []
      field_mappings.each do |field_mapping|
        field = field_mapping['field']
        if field_mapping['priority']
          raise RuntimeError, "Cannot have duplicate priorities" if priority[field] == field_mapping['priority']
          priority[field] = field_mapping['priority']
        else
          priority[field] = 1
        end
      end
    end
    true
  end
end
