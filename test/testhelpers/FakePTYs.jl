# This file is a part of Julia. License is MIT: https://julialang.org/license

module FakePTYs

@static if Sys.iswindows()
    push!(LOAD_PATH, Sys.STDLIB)
    using Sockets
    Sockets.__init__()
    empty!(LOAD_PATH)
end


function open_fake_pty()
    @static if Sys.iswindows()
        # Fake being cygwin
        pid = string(getpid(), base=16, pad=16)
        pipename = """\\\\?\\pipe\\cygwin-$pid-pty10-abcdefg"""
        server = listen(pipename)
        slave = connect(pipename)
        @assert ccall(:jl_ispty, Cint, (Ptr{Cvoid},), slave.handle) == 1
        master = accept(server)
        close(server)
        # extract just the file descriptor
        fds = Libc.dup(Base._fd(slave))
        close(slave)
        slave = fds
        # convert slave handle to a TTY
        #fds = slave.handle
        #slave.status = Base.StatusClosed
        #slave.handle = C_NULL
        #slave = Base.TTY(fds, Base.StatusOpen)
    else
        O_RDWR = Base.Filesystem.JL_O_RDWR
        O_NOCTTY = Base.Filesystem.JL_O_NOCTTY

        fdm = ccall(:posix_openpt, Cint, (Cint,), O_RDWR | O_NOCTTY)
        fdm == -1 && error("Failed to open PTY master")
        rc = ccall(:grantpt, Cint, (Cint,), fdm)
        rc != 0 && error("grantpt failed")
        rc = ccall(:unlockpt, Cint, (Cint,), fdm)
        rc != 0 && error("unlockpt")

        fds = ccall(:open, Cint, (Ptr{UInt8}, Cint),
            ccall(:ptsname, Ptr{UInt8}, (Cint,), fdm), O_RDWR | O_NOCTTY)

        slave = RawFD(fds)
        # slave = fdio(fds, true)
        # slave = Base.Filesystem.File(RawFD(fds))
        # slave = Base.TTY(RawFD(fds); readable = false)
        master = Base.TTY(RawFD(fdm); readable = true)
    end
    return slave, master
end

function with_fake_pty(f)
    slave, master = open_fake_pty()
    try
        f(slave, master)
    finally
        close(master)
    end
    nothing
end

end
