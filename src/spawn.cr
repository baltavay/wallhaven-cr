require "file_utils"

# Run an external command without `fork()`.
#
# Crystal's `Process.run` forks. That is not safe in this app: the UI thread is
# inside GL/driver code most of the time and there are three other threads
# allocating, so the forked child inherits mutexes that other threads held at
# fork time. The child then runs libglvnd's (and the NVIDIA driver's) `atfork`
# handlers against those locked structures and dies before `exec` — seen as
# `Invalid memory access (signal 11) ... in libGLdispatch.so.0` printed while the
# app keeps rendering. Reproduced: forking ImageMagick from a worker thread while
# the render loop runs hangs the worker; with a window and no rendering, or with
# no window at all, it works.
#
# `posix_spawnp` exists for exactly this case: the kernel does clone+exec with no
# user-space code in between, so no inherited lock can deadlock the child.
#
# Output is redirected to temporary files rather than pipes: reading a file after
# `waitpid` cannot deadlock even if the child writes more than a pipe buffer.
module Spawn
  @[Link("c")]
  lib LibSpawn
    # Not declared by the stdlib; the process environment the child inherits.
    $environ : UInt8**
    # glibc's posix_spawn_file_actions_t is opaque; 256 bytes is ample.
    fun posix_spawn_file_actions_init(actions : UInt8*) : LibC::Int
    fun posix_spawn_file_actions_destroy(actions : UInt8*) : LibC::Int
    fun posix_spawn_file_actions_addopen(actions : UInt8*, fd : LibC::Int,
                                         path : LibC::Char*, oflag : LibC::Int,
                                         mode : LibC::ModeT) : LibC::Int
    fun posix_spawnp(pid : LibC::PidT*, file : LibC::Char*, actions : UInt8*,
                     attrp : Void*, argv : LibC::Char**, envp : LibC::Char**) : LibC::Int
  end

  class Error < Exception
  end

  # O_RDONLY / O_WRONLY / O_CREAT / O_TRUNC from fcntl.h.
  O_RDONLY = 0
  O_WRONLY = 1
  O_CREAT  = 0o100
  O_TRUNC  = 0o1000

  @@counter = Atomic(Int32).new(0)

  record Result, output : String, error : String, exit_code : Int32 do
    def success? : Bool
      exit_code == 0
    end

    # First non-empty line of either stream, for error messages.
    def message : String
      (error.presence || output.presence || "exit #{exit_code}")
        .lines.first?.try(&.strip) || "exit #{exit_code}"
    end
  end

  # Runs `binary args...`, capturing both streams. Raises only when the program
  # cannot be started at all.
  def self.run(binary : String, args : Array(String)) : Result
    id = "#{Process.pid}-#{@@counter.add(1)}"
    out_path = File.join(Dir.tempdir, "wallhaven-cr-#{id}.out")
    err_path = File.join(Dir.tempdir, "wallhaven-cr-#{id}.err")

    actions = Bytes.new(256)
    check LibSpawn.posix_spawn_file_actions_init(actions.to_unsafe)
    begin
      # stdin from /dev/null so a child can never block on a terminal.
      check LibSpawn.posix_spawn_file_actions_addopen(actions.to_unsafe, 0, "/dev/null".to_unsafe, O_RDONLY, 0)
      check LibSpawn.posix_spawn_file_actions_addopen(actions.to_unsafe, 1, out_path.to_unsafe, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
      check LibSpawn.posix_spawn_file_actions_addopen(actions.to_unsafe, 2, err_path.to_unsafe, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

      # `parts` must outlive the spawn call: argv holds pointers into the strings.
      parts = [binary] + args
      argv = build_argv(parts)
      pid = uninitialized LibC::PidT
      rc = LibSpawn.posix_spawnp(pointerof(pid), binary.to_unsafe, actions.to_unsafe,
        Pointer(Void).null, argv.to_unsafe, LibSpawn.environ)
      if rc != 0
        raise Error.new("cannot start #{binary}: #{String.new(LibC.strerror(rc))}")
      end

      status = wait(pid)
      Result.new(read_and_delete(out_path), read_and_delete(err_path), status)
    ensure
      LibSpawn.posix_spawn_file_actions_destroy(actions.to_unsafe)
      File.delete?(out_path) if File.exists?(out_path)
      File.delete?(err_path) if File.exists?(err_path)
    end
  end

  # Convenience for the common "run and fail loudly" case.
  def self.run!(binary : String, args : Array(String)) : String
    result = run(binary, args)
    unless result.success?
      raise Error.new("#{File.basename(binary)} failed: #{result.message}")
    end
    result.output.strip
  end

  private def self.check(rc : LibC::Int) : Nil
    raise Error.new("posix_spawn setup failed: #{String.new(LibC.strerror(rc))}") unless rc == 0
  end

  # NULL-terminated argv. The strings must outlive the call: they are held by
  # the caller's `args` array and by `parts` here.
  private def self.build_argv(parts : Array(String)) : Slice(LibC::Char*)
    argv = Slice(LibC::Char*).new(parts.size + 1, Pointer(LibC::Char).null)
    parts.each_with_index { |part, i| argv[i] = part.to_unsafe }
    argv[parts.size] = Pointer(LibC::Char).null
    argv
  end

  private def self.wait(pid : LibC::PidT) : Int32
    status = 0
    loop do
      waited = LibC.waitpid(pid, pointerof(status), 0)
      next if waited == -1 && Errno.value == Errno::EINTR
      break
    end
    if (status & 0x7f) == 0
      (status >> 8) & 0xff # exited
    else
      128 + (status & 0x7f) # killed by a signal
    end
  end

  private def self.read_and_delete(path : String) : String
    return "" unless File.exists?(path)
    File.read(path)
  rescue
    ""
  end
end
