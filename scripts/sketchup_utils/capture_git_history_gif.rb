#!/usr/bin/env ruby
# frozen_string_literal: true

# For each git revision of a tracked Ruby file (oldest → newest), check out that
# revision into the worktree, run SketchUp via the bridge to load it and run
# optional setup Ruby, take a screenshot, then build an animated GIF with ffmpeg.
#
# Prerequisites: SketchUp bridge listener; ffmpeg on PATH; disposable / scratch .skp
#
# Preset (extendable bed — same as legacy defaults):
#   ruby scripts/sketchup_utils/capture_git_history_gif.rb --preset extendable-bed
#
# Generic example:
#   ruby scripts/sketchup_utils/capture_git_history_gif.rb \
#     --repo . \
#     --git-path scripts/my-tool/run.rb \
#     --load-rel ../scripts/my-tool/run.rb \
#     --eval-after-load "MyTool.clear; MyTool.build" \
#     --out-gif out/history.gif \
#     --out-manifest out/history-manifest.json \
#     --frame-prefix mytool_hist
#
#   ruby scripts/sketchup_utils/capture_git_history_gif.rb --dry-run --write-dry-manifest
#
# Environment: SKETCHUP_BRIDGE_MAX_WAIT=60 (passed through to run_and_wait if set)

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'shellwords'
require 'tmpdir'

PRESETS = {
  'extendable-bed' => {
    git_path: 'scripts/extendable-bed/extendable-bed.rb',
    load_rel: '../scripts/extendable-bed/extendable-bed.rb',
    eval_after_load: "Timmerman::ExtendableBed.clear\nTimmerman::ExtendableBed.create",
    out_gif: 'scripts/extendable-bed/references/extendable-bed-git-history.gif',
    manifest: 'scripts/extendable-bed/references/extendable-bed-git-history-manifest.json',
    frame_prefix: 'eb_git_hist',
    clear_model: true,
    clear_operation_name: 'Git history — full model clear'
  }
}.freeze

def sh!(*argv, chdir:)
  stdout, stderr, status = Open3.capture3(*argv, chdir: chdir)
  raise "#{argv.inspect} failed: #{stderr}" unless status.success?

  stdout
end

def repo_root!(explicit)
  return File.expand_path(explicit) if explicit

  out = sh!('git', 'rev-parse', '--show-toplevel', chdir: Dir.pwd)
  File.expand_path(out.strip)
end

def commits_chronological(repo_root, git_path)
  out = sh!('git', 'log', '--reverse', '--format=%H%x00%s', '--', git_path, chdir: repo_root)
  out.each_line.filter_map do |line|
    line = line.strip
    next if line.empty?

    sha, subject = line.split("\x00", 2)
    next unless sha && subject

    { sha: sha, subject: subject }
  end
end

def write_file_at_revision(repo_root, git_path, worktree_file, sha)
  blob = sh!('git', 'show', "#{sha}:#{git_path}", chdir: repo_root)
  File.write(worktree_file, blob)
end

def command_rb_for_frame(options, index:, sha:, subject:)
  safe_subj = subject.gsub('\\', '\\\\').gsub('"', '\"').delete("\r").tr("\n", ' ')
  shot = format('%s_%03d', options[:frame_prefix], index)
  clear_block = if options[:clear_model]
                  <<~RUBY
                    model = Sketchup.active_model
                    while model.close_active
                    end
                    model.start_operation(#{options[:clear_operation_name].inspect}, true)
                    model.entities.to_a.each { |e| e.erase! if e.valid? }
                    model.commit_operation

                  RUBY
                else
                  ''
                  end

  <<~RUBY
    load File.expand_path('utils.rb', __dir__)
    #{clear_block}script_path = File.expand_path(#{options[:load_rel].inspect}, __dir__)
    load script_path
    #{options[:eval_after_load]}
    SketchupBridgeUtils.take_screenshot(name: "#{shot}", width: #{options[:shot_w]}, height: #{options[:shot_h]})
    "OK #{index} #{sha[0, 7]} #{safe_subj}"
  RUBY
end

def run_bridge(repo_root)
  run_wait = File.join(repo_root, 'sketchup_bridge', 'run_and_wait.rb')
  system({ 'RUBYOPT' => '' }, 'ruby', run_wait)
end

def clear_old_frames(results_dir, frame_prefix)
  Dir.glob(File.join(results_dir, "#{frame_prefix}_*.png")).each { |p| File.delete(p) }
end

def frame_path(results_dir, frame_prefix, index)
  File.join(results_dir, format('%s_%03d.png', frame_prefix, index))
end

def bridge_run_clean?(results_dir)
  path = File.join(results_dir, 'result.txt')
  return false unless File.exist?(path)

  body = File.read(path, encoding: 'UTF-8')
  return false if body.include?('=== BRIDGE NOT CONNECTED ===')

  parts = body.split(/^=== stderr ===$/m, 2)
  return true if parts.size < 2

  err = parts[1].strip
  return true if err.empty?

  !err.match?(/^\s*(SyntaxError|LoadError|NameError|NoMethodError|ArgumentError|StandardError):/m)
end

def dedupe_consecutive_pngs(sorted_paths)
  kept = []
  dropped = []
  last_digest = nil
  sorted_paths.each_with_index do |p, i|
    dig = Digest::SHA256.file(p).digest
    if last_digest && dig == last_digest
      dropped << (i + 1)
      next
    end
    kept << p
    last_digest = dig
  end
  [kept, dropped]
end

def build_gif(repo_root, results_dir, frame_prefix, out_gif, fps:, dedupe:)
  pattern = File.join(results_dir, "#{frame_prefix}_*.png")
  sorted = Dir.glob(pattern).sort
  if sorted.empty?
    warn "No frames matching #{frame_prefix}_*.png in #{results_dir}"
    return [false, []]
  end

  paths, dropped = if dedupe
                     dedupe_consecutive_pngs(sorted)
                   else
                     [sorted, []]
                   end

  if paths.empty?
    warn 'No frames left after deduplication'
    return [false, dropped]
  end

  if dedupe && dropped.any?
    puts "\nGIF dedupe: #{sorted.size} captures → #{paths.size} unique consecutive frames (dropped indices: #{dropped.join(', ')})"
  end

  seq_prefix = "#{frame_prefix}_gif"
  Dir.glob(File.join(results_dir, "#{seq_prefix}_*.png")).each { |f| File.delete(f) }
  paths.each_with_index do |src, i|
    FileUtils.cp(src, File.join(results_dir, format('%s_%03d.png', seq_prefix, i + 1)))
  end

  FileUtils.mkdir_p(File.dirname(out_gif))
  filter = "fps=#{fps},scale=1000:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer"
  in_pattern = File.join(results_dir, "#{seq_prefix}_*.png")
  cmd = [
    'ffmpeg', '-y', '-framerate', fps.to_s, '-pattern_type', 'glob', '-i', in_pattern,
    '-vf', filter,
    '-loop', '0',
    out_gif
  ]
  ok = system(*cmd)
  Dir.glob(File.join(results_dir, "#{seq_prefix}_*.png")).each { |f| File.delete(f) }

  unless ok
    warn "ffmpeg failed: #{cmd.shelljoin}"
    return [false, dropped]
  end

  [true, dropped]
end

# --- CLI ----------------------------------------------------------------------

options = {
  preset: nil,
  repo: nil,
  git_path: nil,
  worktree: nil,
  load_rel: nil,
  eval_after_load: nil,
  eval_file: nil,
  out_gif: nil,
  manifest: nil,
  frame_prefix: 'git_hist',
  clear_model: true,
  clear_operation_name: 'Git history — full model clear',
  shot_w: 1400,
  shot_h: 900,
  dry: false,
  write_manifest: false,
  dedupe: true,
  fps: 1.2
}

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options]\n\nPresets: #{PRESETS.keys.join(', ')}"
  o.on('--preset NAME', String, "Load defaults from built-in preset (#{PRESETS.keys.join(', ')})") { |v| options[:preset] = v }
  o.on('--repo ROOT', 'Git repo root (default: git rev-parse from cwd)') { |v| options[:repo] = v }
  o.on('--git-path PATH', 'Repo-relative path for git log / git show') { |v| options[:git_path] = v }
  o.on('--worktree PATH', 'File on disk to overwrite each revision (default: <repo>/<git-path>)') { |v| options[:worktree] = v }
  o.on('--load-rel PATH', "Path for File.expand_path(..., __dir__) from sketchup_bridge/") { |v| options[:load_rel] = v }
  o.on('--eval-after-load CODE', 'Ruby run in SketchUp after load (use \\n for newlines)') { |v| options[:eval_after_load] = v.gsub('\\n', "\n") }
  o.on('--eval-file PATH', 'File whose contents are Ruby run after load (overrides --eval-after-load)') { |v| options[:eval_file] = v }
  o.on('--out-gif PATH', 'Output GIF (repo-relative or absolute)') { |v| options[:out_gif] = v }
  o.on('--out-manifest PATH', 'Output manifest JSON path') { |v| options[:manifest] = v }
  o.on('--frame-prefix PREFIX', 'PNG basename prefix (default: git_hist or preset)') { |v| options[:frame_prefix] = v }
  o.on('--no-clear-model', 'Do not erase all top-level entities before each frame') { options[:clear_model] = false }
  o.on('--clear-op-name NAME', 'SketchUp operation name when clearing model') { |v| options[:clear_operation_name] = v }
  o.on('--width N', Integer, 'Screenshot width (default 1400)') { |v| options[:shot_w] = v }
  o.on('--height N', Integer, 'Screenshot height (default 900)') { |v| options[:shot_h] = v }
  o.on('--dry-run', 'List commits only; do not touch SketchUp or worktree file') { options[:dry] = true }
  o.on('--write-dry-manifest', 'With --dry-run, write --out-manifest JSON (needs path)') { options[:write_manifest] = true }
  o.on('--no-dedupe', 'Keep consecutive duplicate screenshots in the GIF') { options[:dedupe] = false }
  o.on('--fps F', Float, 'Output GIF frame rate (default 1.2)') { |v| options[:fps] = v }
end.parse!

if options[:preset]
  p = PRESETS[options[:preset]]
  abort "Unknown preset: #{options[:preset].inspect}" unless p

  options[:git_path] ||= p[:git_path]
  options[:load_rel] ||= p[:load_rel]
  options[:eval_after_load] ||= p[:eval_after_load]
  options[:out_gif] ||= p[:out_gif]
  options[:manifest] ||= p[:manifest]
  options[:frame_prefix] = p[:frame_prefix] if options[:frame_prefix] == 'git_hist' && p[:frame_prefix]
  options[:clear_model] = p[:clear_model] if p.key?(:clear_model)
  options[:clear_operation_name] = p[:clear_operation_name] if p[:clear_operation_name]
end

# Default preset for backward compatibility: extendable-bed when invoked with no generic overrides
unless options[:git_path]
  options[:preset] ||= 'extendable-bed'
  p = PRESETS.fetch(options[:preset])
  options[:git_path] = p[:git_path]
  options[:load_rel] ||= p[:load_rel]
  options[:eval_after_load] ||= p[:eval_after_load]
  options[:out_gif] ||= p[:out_gif]
  options[:manifest] ||= p[:manifest]
  options[:frame_prefix] = p[:frame_prefix] if options[:frame_prefix] == 'git_hist'
  options[:clear_model] = p[:clear_model] if p.key?(:clear_model)
  options[:clear_operation_name] = p[:clear_operation_name] if p[:clear_operation_name]
end

repo_root = repo_root!(options[:repo])

if options[:eval_file]
  options[:eval_after_load] = File.read(File.expand_path(options[:eval_file], repo_root), encoding: 'UTF-8')
end

abort 'Missing --eval-after-load or --eval-file (or use --preset)' if options[:eval_after_load].to_s.strip.empty?
abort 'Missing --load-rel (or use --preset)' if options[:load_rel].to_s.strip.empty?
abort 'Missing --out-gif (or use --preset)' if options[:out_gif].to_s.strip.empty?
abort 'Missing --out-manifest (or use --preset)' if options[:manifest].to_s.strip.empty?
worktree_file = if options[:worktree]
                  File.expand_path(options[:worktree], repo_root)
                else
                  File.join(repo_root, options[:git_path])
                end
bridge_dir = File.join(repo_root, 'sketchup_bridge')
command_rb = File.join(bridge_dir, 'command.rb')
run_wait = File.join(bridge_dir, 'run_and_wait.rb')
results_dir = File.join(bridge_dir, 'results')
out_gif_abs = File.expand_path(options[:out_gif], repo_root)
manifest_abs = File.expand_path(options[:manifest], repo_root)

config = options.merge(
  repo_root: repo_root,
  worktree_file: worktree_file,
  load_rel: options[:load_rel],
  eval_after_load: options[:eval_after_load],
  out_gif: out_gif_abs,
  manifest: manifest_abs,
  frame_prefix: options[:frame_prefix]
)

Dir.chdir(repo_root) do
  list = commits_chronological(repo_root, options[:git_path])
  if list.empty?
    warn "No commits found for #{options[:git_path]}"
    exit 1
  end

  puts "Commits (#{list.size}, oldest → newest) for #{options[:git_path]}:"
  list.each_with_index { |c, i| puts "  #{i + 1}. #{c[:sha][0, 7]}  #{c[:subject]}" }

  if options[:dry]
    if options[:write_manifest]
      frames = list.each_with_index.map { |c, i| { 'index' => i + 1, 'sha' => c[:sha], 'subject' => c[:subject] } }
      File.write(manifest_abs, JSON.pretty_generate(
                                 'frames' => frames,
        'gif' => { 'dry_run' => true, 'dedupe_consecutive' => options[:dedupe], 'git_path' => options[:git_path] }
                               ))
      puts "\nWrote #{manifest_abs}"
    end
    exit 0
  end

  unless File.exist?(run_wait)
    warn "Missing #{run_wait}"
    exit 1
  end

  wt_backup = File.join(Dir.tmpdir, "git-history-gif-worktree-#{Process.pid}#{File.extname(worktree_file)}")
  cmd_backup = File.join(Dir.tmpdir, "sketchup-bridge-command-restore-#{Process.pid}.rb")
  FileUtils.cp(worktree_file, wt_backup)
  FileUtils.cp(command_rb, cmd_backup) if File.exist?(command_rb)
  FileUtils.mkdir_p(results_dir)
  clear_old_frames(results_dir, config[:frame_prefix])

  manifest = []
  begin
    list.each_with_index do |c, i|
      idx = i + 1
      puts "\n--- Frame #{idx}/#{list.size} #{c[:sha][0, 7]} ---"
      write_file_at_revision(repo_root, options[:git_path], worktree_file, c[:sha])
      File.write(command_rb, command_rb_for_frame(config, index: idx, sha: c[:sha], subject: c[:subject]))
      ok = run_bridge(repo_root)
      fp = frame_path(results_dir, config[:frame_prefix], idx)
      clean = bridge_run_clean?(results_dir)
      unless ok && File.exist?(fp) && clean
        warn "Bridge or screenshot failed for #{c[:sha][0, 7]}."
        warn "  run_bridge: #{ok}, frame exists: #{File.exist?(fp)}, clean: #{clean}"
        if File.exist?(File.join(results_dir, 'result.txt'))
          warn File.read(File.join(results_dir, 'result.txt'), encoding: 'UTF-8').lines.first(40).join
        end
        exit 2
      end
      manifest << { index: idx, sha: c[:sha], subject: c[:subject], frame: File.basename(fp) }
      puts File.read(File.join(results_dir, 'result.txt'), encoding: 'UTF-8').lines.first(8).join
    end

    gif_ok, dropped_indices = build_gif(repo_root, results_dir, config[:frame_prefix], out_gif_abs, fps: options[:fps],
                                        dedupe: options[:dedupe])
    exit 3 unless gif_ok

    manifest_payload = {
      'frames' => manifest,
      'gif' => {
        'dedupe_consecutive' => options[:dedupe],
        'capture_count' => manifest.size,
        'gif_frame_count' => manifest.size - dropped_indices.size,
        'dropped_capture_indices_duplicate_of_previous' => dropped_indices,
        'git_path' => options[:git_path]
      }
    }
    File.write(manifest_abs, JSON.pretty_generate(manifest_payload))
    puts "\nGIF: #{out_gif_abs}"
    puts "Manifest: #{manifest_abs}"
    puts "Frames: #{results_dir}/#{config[:frame_prefix]}_*.png"
  ensure
    FileUtils.cp(wt_backup, worktree_file)
    File.delete(wt_backup) if File.exist?(wt_backup)
    if File.exist?(cmd_backup)
      FileUtils.cp(cmd_backup, command_rb)
      File.delete(cmd_backup)
    end
    puts "\nRestored working copy: #{worktree_file}"
    puts 'Restored: sketchup_bridge/command.rb'
  end
end
