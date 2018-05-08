require 'colored'
require 'git'
require 'date'
require 'fileutils'
require 'timeout'

class GitSync::Source::Single < GitSync::Source::Base
  attr_reader :from, :to

  def initialize(from, to, opts={})
    super()
    @dry_run = opts[:dry_run] || false
    @from = from
    @to = to
    @done = false
    @mutex = Mutex.new
    @queue = nil

    # If it's a local repository
    if @from.start_with? "/"
      if File.exist? @from
        return
      elsif File.exist? "#{@from}.git" # Bare
        @from = "#{@from}.git"
      else
        throw "Unable to sync '#{@from}"
      end
    end
  end

  def to_s
    "<Source::Single '#{from}' -> '#{to}'>"
  end

  def work(queue)
    @queue = queue
    @mutex.synchronize { sync! }
  end

  def wait
    loop do
      sleep 0.1
      return if @done
    end
  end

  def git
    @git ||= Git.bare(to)
  end

  def check_corrupted
    puts "[#{DateTime.now} #{to}] Checking for corruption".yellow
    unless git.fsck
      puts "[#{DateTime.now} #{to}] Repository OK".green
      return
    end

    handle_corrupted
  end

  def handle_corrupted
    puts "[#{DateTime.now} #{to}] Corrupted".red
    # Remove the complete repository by default
    FileUtils.rm_rf(to)
    exit 1
  end

  def sync!
    puts "Sync '#{from}' to '#{to} (dry run: #{dry_run})".blue

    if File.exists?(to) and not File.exists?(File.join(to, "objects"))
      handle_corrupted
    end

    pid = nil
    if not File.exist?(to)
      puts "[#{DateTime.now} #{to}] Cloning ..."
      if not dry_run
        pid = Process.fork {
          Git.clone(from, File.basename(to), path: File.dirname(to), mirror: true)
        }
      end
    else
      puts "[#{DateTime.now} #{to}] Updating ..."
      if not dry_run
        pid = Process.fork {
          add_remote = true

          # Look for the remove and if it needs to be updated
          git.remotes.each do |remote|
            next if remote.name != "gitsync"

            if remote.url != from
              git.remove_remote("gitsync")
            else
              add_remote = false
              break
            end
          end

          if add_remote
            git.add_remote("gitsync", from, :mirror => 'fetch')
          end

          begin
            git.fetch("gitsync")
          rescue Git::GitExecuteError => e
            puts "[#{DateTime.now} #{to}] Issue with fetching: #{e}".red
            check_corrupted
          end
        }
      end
    end

    if pid
      begin
        Timeout.timeout(timeout) {
          Process.waitpid(pid)

          # If there was any issue in the sync, add back to the queue
          if $?.exitstatus != 0
            STDERR.puts "Fetch process #{pid} failed: #{$?.exitstatus}".red
            @queue << self
          end
        }

      # In case of timeout, send a series of SIGTERM and SIGKILL
      rescue Timeout::Error
        STDERR.puts "Timeout: sending TERM to #{pid}".red
        Process.kill("TERM", pid)

        begin
          Timeout.timeout(20) {
            Process.waitpid(pid)
          }
        rescue Timeout::Error
          STDERR.puts "Timeout: sending KILL to #{pid}".red
          Process.kill("KILL", pid)
          Process.waitpid(pid)
        end

        # Add ourselves back at the end of the queue
        @queue << self
      end
    end

    puts "[#{DateTime.now} #{to}] Done ..."
    @done = true
  end
end
