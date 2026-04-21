module Procodile
  class IssueTracker
    @runtime_issues : Hash(String, RuntimeIssue) = {} of String => RuntimeIssue

    def runtime_issues : Array(RuntimeIssue)
      @runtime_issues.values.sort_by! { |issue| {issue.process_name, issue.type.to_s} }
    end

    def report(type : RuntimeIssueType, process_name : String, message : String) : Nil
      key = runtime_issue_key(type, process_name)
      @runtime_issues[key] = RuntimeIssue.new(
        key: key,
        type: type,
        process_name: process_name,
        message: message
      )
    end

    def resolve(type : RuntimeIssueType, process_name : String) : Nil
      @runtime_issues.delete(runtime_issue_key(type, process_name))
    end

    def clear_process(process_name : String) : Nil
      RuntimeIssueType.values.each do |type|
        resolve(type, process_name)
      end
    end

    private def runtime_issue_key(type : RuntimeIssueType, process_name : String) : String
      "#{type.to_s.underscore}:#{process_name}"
    end

    enum RuntimeIssueType
      ProcessFailedPermanently
      ScheduledRunFailed
      InvalidSchedule
      ScheduledRunSkippedRepeatedly
    end

    struct RuntimeIssue
      include JSON::Serializable

      getter key : String
      getter type : RuntimeIssueType
      getter process_name : String
      getter message : String

      def initialize(
        @key : String,
        @type : RuntimeIssueType,
        @process_name : String,
        @message : String,
      )
      end
    end
  end
end
