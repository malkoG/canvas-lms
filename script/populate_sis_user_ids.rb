# frozen_string_literal: true

#
# Copyright (C) 2025 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

#
# SIS User ID Population Script
#
# This script ensures all enrolled students have:
# 1. A pseudonym (login account) in their course's root account
# 2. A sis_user_id set on that pseudonym (for LTI NRPS compatibility)
# 3. Their enrollments linked to the pseudonym via sis_pseudonym_id
#
# Usage with rails runner:
#   docker compose run --rm web rails runner script/populate_sis_user_ids.rb
#   docker compose run --rm web rails runner script/populate_sis_user_ids.rb analyze
#   docker compose run --rm web rails runner script/populate_sis_user_ids.rb verify
#   docker compose run --rm web rails runner script/populate_sis_user_ids.rb rollback
#
# Environment variables:
#   PATTERN=Canvas-%05d   - Pattern for sis_user_id generation (default: Canvas-00001)
#   BATCH_SIZE=1000       - Number of records to process per batch
#   ENROLLMENT_TYPES=StudentEnrollment,TeacherEnrollment  - Enrollment types to process
#

# rubocop:disable Rails/Output

class SisUserIdPopulator
  BATCH_SIZE = (ENV["BATCH_SIZE"] || 1000).to_i
  DEFAULT_PATTERN = ENV["PATTERN"] || "Canvas-%05d"
  ENROLLMENT_TYPES = (ENV["ENROLLMENT_TYPES"] || "StudentEnrollment").split(",")

  def initialize
    @pattern = DEFAULT_PATTERN
    @stats = {
      pseudonyms_created: 0,
      pseudonyms_updated: 0,
      enrollments_linked: 0,
      failed: 0,
      skipped: 0,
      errors: []
    }
  end

  def analyze
    print_header("ANALYSIS MODE")

    puts "Analyzing enrolled students and pseudonyms..."
    puts ""

    # Find all active enrollments
    active_enrollments = get_enrollments_scope
    total_enrollments = active_enrollments.count
    unique_students = active_enrollments.select(:user_id).distinct.count

    puts "Enrollment Statistics:"
    puts "-" * 70
    puts "Total active enrollments (#{ENROLLMENT_TYPES.join(', ')}): #{total_enrollments}"
    puts "Unique users enrolled: #{unique_students}"
    puts ""

    # Check how many have pseudonyms
    students_with_pseudonyms = User.where(
      id: active_enrollments.select(:user_id).distinct
    ).joins(:pseudonyms).where(pseudonyms: { workflow_state: "active" }).distinct.count

    students_without_pseudonyms = unique_students - students_with_pseudonyms

    puts "Pseudonym Status:"
    puts "-" * 70
    puts "Users WITH pseudonyms: #{students_with_pseudonyms}"
    puts "Users WITHOUT pseudonyms: #{students_without_pseudonyms}"
    puts ""

    # Check sis_user_id status
    students_with_sis_id = User.where(
      id: active_enrollments.select(:user_id).distinct
    ).joins(:pseudonyms).where.not(pseudonyms: { sis_user_id: nil })
     .where(pseudonyms: { workflow_state: "active" }).distinct.count

    students_without_sis_id = unique_students - students_with_sis_id

    puts "SIS User ID Status:"
    puts "-" * 70
    puts "Users WITH sis_user_id: #{students_with_sis_id}"
    puts "Users WITHOUT sis_user_id: #{students_without_sis_id}"
    puts ""

    # Check enrollment linkage
    enrollments_with_sis_pseudonym = active_enrollments.where.not(sis_pseudonym_id: nil).count
    enrollments_without_sis_pseudonym = total_enrollments - enrollments_with_sis_pseudonym

    puts "Enrollment Linkage Status:"
    puts "-" * 70
    puts "Enrollments linked to sis_pseudonym: #{enrollments_with_sis_pseudonym}"
    puts "Enrollments NOT linked: #{enrollments_without_sis_pseudonym}"
    puts ""

    # Show examples of users without pseudonyms
    if students_without_pseudonyms > 0
      puts "Sample users WITHOUT pseudonyms (first 5):"
      puts "-" * 70
      User.where(
        id: active_enrollments.select(:user_id).distinct
      ).left_joins(:pseudonyms)
       .where(pseudonyms: { id: nil })
       .limit(5)
       .each do |user|
        puts "  User ID: #{user.id}, Name: #{user.name}, Email: #{user.email}"
      end
      puts ""
    end

    # Show examples of what will be generated
    puts "Example SIS IDs that will be generated (pattern: '#{@pattern}'):"
    puts "-" * 70
    [1, 123, 9999, 123456].each do |sample_id|
      puts "  User ID #{sample_id} -> '#{@pattern % sample_id}'"
    end

    print_footer
  end

  def update
    print_header("UPDATE MODE")

    enrollments = get_enrollments_scope
    total_count = enrollments.count

    puts "Processing #{total_count} enrollments..."
    puts "Pattern: #{@pattern}"
    puts "Batch size: #{BATCH_SIZE}"
    puts ""
    puts "Legend: C=Created, U=Updated, L=Linked, S=Skipped, F=Failed"
    puts ""

    processed = 0
    enrollments.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each do |enrollment|
        process_enrollment(enrollment)
        processed += 1

        if processed % 100 == 0
          print_progress(processed, total_count)
        end
      end
    end

    puts "\n"
    print_summary
  end

  def verify
    print_header("VERIFICATION MODE")

    puts "Verifying results..."
    puts ""

    active_enrollments = get_enrollments_scope
    total = active_enrollments.count
    unique_students = active_enrollments.select(:user_id).distinct.count

    with_sis_id = User.where(id: active_enrollments.select(:user_id).distinct)
                      .joins(:pseudonyms)
                      .where.not(pseudonyms: { sis_user_id: nil })
                      .where(pseudonyms: { workflow_state: "active" })
                      .distinct.count

    linked = active_enrollments.where.not(sis_pseudonym_id: nil).count

    puts "Verification Results:"
    puts "-" * 70
    puts "Total enrollments: #{total}"
    puts "Unique users: #{unique_students}"
    puts "Users with sis_user_id: #{with_sis_id}/#{unique_students} " \
         "(#{percentage(with_sis_id, unique_students)}%)"
    puts "Enrollments linked to sis_pseudonym: #{linked}/#{total} " \
         "(#{percentage(linked, total)}%)"
    puts ""

    # Show sample results
    if linked > 0
      puts "Sample results (5 random):"
      puts "-" * 70
      active_enrollments.where.not(sis_pseudonym_id: nil)
                        .order("RANDOM()")
                        .limit(5)
                        .each do |e|
        pseudo = e.sis_pseudonym
        puts "  User #{e.user_id} (#{e.user.name}): SIS ID = '#{pseudo&.sis_user_id}'"
      end
    end

    print_footer
  end

  def rollback
    print_header("ROLLBACK MODE")

    pattern_prefix = @pattern.split("%").first
    puts "This will remove sis_user_id values matching pattern: #{pattern_prefix}*"
    puts ""

    matching = Pseudonym.active.where("sis_user_id LIKE ?", "#{pattern_prefix}%")
    count = matching.count

    if count == 0
      puts "No pseudonyms found matching pattern '#{pattern_prefix}%'."
      print_footer
      return
    end

    puts "Found #{count} pseudonyms with sis_user_id matching pattern."
    puts ""
    puts "Sample (first 5):"
    puts "-" * 70
    matching.limit(5).each do |p|
      puts "  User #{p.user_id} (#{p.unique_id}): sis_user_id = '#{p.sis_user_id}'"
    end
    puts ""

    puts "WARNING: This will remove sis_user_id from #{count} pseudonyms!"
    puts "Press Ctrl+C now to cancel, or wait 5 seconds to continue..."
    sleep 5

    updated = 0
    failed = 0

    matching.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each do |pseudo|
        pseudo.sis_user_id = nil
        if pseudo.save(validate: false)
          updated += 1
          print "." if updated % 100 == 0
        else
          failed += 1
        end
      end
    end

    puts "\n"
    puts "Rollback complete!"
    puts "Updated: #{updated}, Failed: #{failed}"

    print_footer
  end

  private

  def get_enrollments_scope
    Enrollment.active.where(type: ENROLLMENT_TYPES)
  end

  def process_enrollment(enrollment)
    user = enrollment.user
    course = enrollment.course
    root_account = course.root_account

    # Find or create pseudonym
    pseudonym = user.pseudonyms.active.find_by(account_id: root_account.id)

    if pseudonym.nil?
      pseudonym = create_pseudonym(user, root_account)
      return unless pseudonym
    else
      update_pseudonym_sis_id(pseudonym, user.id, root_account.id)
    end

    # Link enrollment to pseudonym
    link_enrollment(enrollment, pseudonym)
  rescue => e
    @stats[:failed] += 1
    @stats[:errors] << "Error processing enrollment #{enrollment.id}: #{e.message}"
    print "F"
  end

  def create_pseudonym(user, root_account)
    unique_id = user.email || "canvas_user_#{user.id}@generated.local"

    pseudonym = user.pseudonyms.build(
      account: root_account,
      unique_id: unique_id,
      sis_user_id: @pattern % user.id
    )

    pseudonym.send(:generate_temporary_password)

    if pseudonym.save
      @stats[:pseudonyms_created] += 1
      print "C"
      pseudonym
    else
      @stats[:failed] += 1
      @stats[:errors] << "Failed to create pseudonym for user #{user.id}: #{pseudonym.errors.full_messages.join(', ')}"
      print "F"
      nil
    end
  end

  def update_pseudonym_sis_id(pseudonym, user_id, account_id)
    return unless pseudonym.sis_user_id.nil?

    new_sis_id = @pattern % user_id

    # Check for conflicts
    conflict = Pseudonym.where(
      account_id: account_id,
      sis_user_id: new_sis_id
    ).where.not(id: pseudonym.id).exists?

    if conflict
      @stats[:skipped] += 1
      @stats[:errors] << "Conflict: sis_user_id '#{new_sis_id}' already exists for user #{user_id}"
      print "S"
      return
    end

    pseudonym.sis_user_id = new_sis_id

    if pseudonym.save
      @stats[:pseudonyms_updated] += 1
      print "U"
    else
      @stats[:failed] += 1
      @stats[:errors] << "Failed to update pseudonym #{pseudonym.id}: #{pseudonym.errors.full_messages.join(', ')}"
      print "F"
    end
  end

  def link_enrollment(enrollment, pseudonym)
    return if enrollment.sis_pseudonym_id == pseudonym.id

    enrollment.sis_pseudonym_id = pseudonym.id

    if enrollment.save
      @stats[:enrollments_linked] += 1
      print "L"
    else
      @stats[:failed] += 1
      @stats[:errors] << "Failed to link enrollment #{enrollment.id}: #{enrollment.errors.full_messages.join(', ')}"
      print "F"
    end
  end

  def print_header(mode)
    puts ""
    puts "=" * 70
    puts "SIS User ID Population Script"
    puts "=" * 70
    puts "Mode: #{mode}"
    puts "Timestamp: #{Time.zone.now}"
    puts "=" * 70
    puts ""
  end

  def print_footer
    puts ""
    puts "=" * 70
    puts "Complete!"
    puts "=" * 70
    puts ""
  end

  def print_progress(current, total)
    percent = (current.to_f / total * 100).round(1)
    puts "\n[#{Time.zone.now.strftime('%H:%M:%S')}] Progress: #{current}/#{total} (#{percent}%)"
  end

  def print_summary
    puts ""
    puts "=" * 70
    puts "UPDATE SUMMARY"
    puts "=" * 70
    puts "Pseudonyms created: #{@stats[:pseudonyms_created]}"
    puts "Pseudonyms updated with sis_user_id: #{@stats[:pseudonyms_updated]}"
    puts "Enrollments linked to sis_pseudonym: #{@stats[:enrollments_linked]}"
    puts "Skipped (conflicts): #{@stats[:skipped]}"
    puts "Failed: #{@stats[:failed]}"
    puts "=" * 70

    if @stats[:errors].any?
      puts ""
      puts "Errors (first 10):"
      puts "-" * 70
      @stats[:errors].first(10).each { |err| puts "  - #{err}" }
      if @stats[:errors].size > 10
        puts "  ... and #{@stats[:errors].size - 10} more"
      end
    end

    print_footer
  end

  def percentage(part, whole)
    return 0 if whole.zero?

    (part.to_f / whole * 100).round(1)
  end
end

# Main execution
def main
  command = ARGV[0] || "update"

  populator = SisUserIdPopulator.new

  case command
  when "analyze"
    populator.analyze
  when "update"
    populator.update
  when "verify"
    populator.verify
  when "rollback"
    populator.rollback
  else
    puts "Unknown command: #{command}"
    puts ""
    puts "Usage:"
    puts "  rails runner script/populate_sis_user_ids.rb [command]"
    puts ""
    puts "Commands:"
    puts "  update   - Update pseudonyms and link enrollments (default)"
    puts "  analyze  - Analyze current state"
    puts "  verify   - Verify results after update"
    puts "  rollback - Remove generated sis_user_id values"
    puts ""
    puts "Environment variables:"
    puts "  PATTERN=Canvas-%05d        - SIS ID pattern (default: Canvas-00001)"
    puts "  BATCH_SIZE=1000            - Batch size for processing"
    puts "  ENROLLMENT_TYPES=...       - Comma-separated enrollment types (default: StudentEnrollment)"
    puts ""
    puts "Examples:"
    puts "  docker compose run --rm web rails runner script/populate_sis_user_ids.rb"
    puts "  docker compose run --rm web rails runner script/populate_sis_user_ids.rb analyze"
    puts "  docker compose run --rm web rails runner script/populate_sis_user_ids.rb verify"
    puts "  PATTERN=SIS-%06d docker compose run --rm web rails runner script/populate_sis_user_ids.rb"
    exit 1
  end
end

main if __FILE__ == $PROGRAM_NAME

# rubocop:enable Rails/Output
