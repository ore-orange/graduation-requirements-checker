# frozen_string_literal: true

require 'open3'

module CurriculumImport
  # Ghostscript など外部コマンドを、時間を決めて実行する。止まったコマンドでリクエストを止めない。
  module GsRunner
    class TimeoutError < StandardError; end

    # command を timeout 秒だけ実行し、[標準出力(バイナリ), 標準エラー, 終了状態] を返す。
    # 超えたら止めて TimeoutError。コマンドが無ければ Errno::ENOENT。
    def self.run(*command, timeout:)
      Open3.popen3(*command) do |stdin, stdout, stderr, waiter|
        stdin.close
        stdout.binmode
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        unless waiter.join(timeout)
          kill(waiter)
          [out, err].each(&:join) # 殺すと両方の管が閉じて読み終わる。読み手を残したまま管を閉じない
          raise TimeoutError, "#{command.first} が #{timeout} 秒で終わりませんでした"
        end
        [out.value, err.value, waiter.value]
      end
    end

    def self.kill(waiter)
      Process.kill('KILL', waiter.pid)
      waiter.join
    rescue Errno::ESRCH
      nil
    end
    private_class_method :kill
  end
end

