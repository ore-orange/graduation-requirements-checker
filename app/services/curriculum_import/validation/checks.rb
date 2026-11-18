# frozen_string_literal: true

module CurriculumImport
  class Validation
    # 検査のまとまりの共通部分。1つの Checks は入力を読み、見つけたものを findings に足す。
    class Checks
      include Values

      def initialize(input, findings)
        @input = input
        @findings = findings
      end

      def run
        raise NotImplementedError, "#{self.class}#run"
      end

      private

      attr_reader :input, :findings

      # 規則(入れ子も)に付く指摘。target は規則の場所(id)のまま、見せる文字は規則の名前にする。
      def node_blocking(node, reason)
        findings.blocking(:rule, node.target, reason, label: input.node_name(node))
      end

      def node_warning(node, reason)
        findings.warning(:rule, node.target, reason, label: input.node_name(node))
      end
    end
  end
end

