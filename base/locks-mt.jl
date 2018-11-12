# This file is a part of Julia. License is MIT: https://julialang.org/license

import .Base: _uv_hook_close, unsafe_convert,
    lock, trylock, unlock, islocked, wait, notify,
    AbstractLock, GenericCondition, GenericReentrantLock, GenericEvent

export ConditionMT, EventMT, ReentrantLockMT

# Important Note: these low-level primitives exported here
#   are typically not for general usage
export SpinLock, RecursiveSpinLock, Mutex

##########################################
# Atomic Locks
##########################################

# Test-and-test-and-set spin locks are quickest up to about 30ish
# contending threads. If you have more contention than that, perhaps
# a lock is the wrong way to synchronize.
"""
    TatasLock()

See [`SpinLock`](@ref).
"""
struct TatasLock <: AbstractLock
    handle::Atomic{Int}
    TatasLock() = new(Atomic{Int}(0))
end

"""
    SpinLock()

Create a non-reentrant lock.
Recursive use will result in a deadlock.
Each [`lock`](@ref) must be matched with an [`unlock`](@ref).

Test-and-test-and-set spin locks are quickest up to about 30ish
contending threads. If you have more contention than that, perhaps
a lock is the wrong way to synchronize.

See also [`RecursiveSpinLock`](@ref) for a version that permits recursion.

See also [`Mutex`](@ref) for a more efficient version on one core or if the
lock may be held for a considerable length of time.
"""
const SpinLock = TatasLock

function lock(l::TatasLock)
    while true
        if l.handle[] == 0
            p = atomic_xchg!(l.handle, 1)
            if p == 0
                return
            end
        end
        ccall(:jl_cpu_pause, Cvoid, ())
        # Temporary solution before we have gc transition support in codegen.
        ccall(:jl_gc_safepoint, Cvoid, ())
    end
end

function trylock(l::TatasLock)
    if l.handle[] == 0
        return atomic_xchg!(l.handle, 1) == 0
    end
    return false
end

function unlock(l::TatasLock)
    l.handle[] = 0
    ccall(:jl_cpu_wake, Cvoid, ())
    return
end

function islocked(l::TatasLock)
    return l.handle[] != 0
end


"""
    RecursiveTatasLock()

See [`RecursiveSpinLock`](@ref).
"""
struct RecursiveTatasLock <: AbstractLock
    ownertid::Atomic{Int16}
    handle::Atomic{Int}
    RecursiveTatasLock() = new(Atomic{Int16}(0), Atomic{Int}(0))
end

"""
    RecursiveSpinLock()

Creates a reentrant lock.
The same thread can acquire the lock as many times as required.
Each [`lock`](@ref) must be matched with an [`unlock`](@ref).

See also [`SpinLock`](@ref) for a slightly faster version.

See also [`Mutex`](@ref) for a more efficient version on one core or if the lock
may be held for a considerable length of time.
"""
const RecursiveSpinLock = RecursiveTatasLock


function lock(l::RecursiveTatasLock)
    if l.ownertid[] == threadid()
        l.handle[] += 1
        return
    end
    while true
        if l.handle[] == 0
            if atomic_cas!(l.handle, 0, 1) == 0
                l.ownertid[] = threadid()
                return
            end
        end
        ccall(:jl_cpu_pause, Cvoid, ())
        # Temporary solution before we have gc transition support in codegen.
        ccall(:jl_gc_safepoint, Cvoid, ())
    end
end

function trylock(l::RecursiveTatasLock)
    if l.ownertid[] == threadid()
        l.handle[] += 1
        return true
    end
    if l.handle[] == 0
        if atomic_cas!(l.handle, 0, 1) == 0
            l.ownertid[] = threadid()
            return true
        end
        return false
    end
    return false
end

function unlock(l::RecursiveTatasLock)
    l.ownertid[] == threadid() || error("unlock from wrong thread")
    n = l.handle[]
    n != 0 || error("unlock count must match lock count")
    if l.handle[] == 1
        l.ownertid[] = 0
        l.handle[] = 0
        ccall(:jl_cpu_wake, Cvoid, ())
    else
        l.handle[] = n - 1
    end
    return
end

function unlockall(l::RecursiveTatasLock)
    l.ownertid[] == threadid() || error("unlock from wrong thread")
    n = l.handle[]
    n != 0 || error("unlock count must match lock count")
    l.ownertid[] = 0
    l.handle[] = 0
    ccall(:jl_cpu_wake, Cvoid, ())
    return n
end

function relockall(l::RecursiveTatasLock, n::Int)
    lock(l)
    n1 = l.handle[]
    l.handle[] = n
    n1 == 1 || error("concurrency violation detected")
    return
end

function islocked(l::RecursiveTatasLock)
    return l.handle[] != 0
end


##########################################
# System Mutexes
##########################################

# These are mutexes from libuv.
const UV_MUTEX_SIZE = ccall(:jl_sizeof_uv_mutex, Cint, ())

"""
    Mutex()

These are standard system mutexes for locking critical sections of logic.

On Windows, this is a critical section object,
on pthreads, this is a `pthread_mutex_t`.

See also [`SpinLock`](@ref) for a lighter-weight lock.
"""
mutable struct Mutex <: AbstractLock
    ownertid::Int16
    handle::Ptr{Cvoid}
    function Mutex()
        m = new(zero(Int16), Libc.malloc(UV_MUTEX_SIZE))
        ccall(:uv_mutex_init, Cvoid, (Ptr{Cvoid},), m.handle)
        finalizer(_uv_hook_close, m)
        return m
    end
end

unsafe_convert(::Type{Ptr{Cvoid}}, m::Mutex) = m.handle

function _uv_hook_close(x::Mutex)
    h = x.handle
    if h != C_NULL
        x.handle = C_NULL
        ccall(:uv_mutex_destroy, Cvoid, (Ptr{Cvoid},), h)
        Libc.free(h)
        nothing
    end
end

function lock(m::Mutex)
    m.ownertid == threadid() && error("concurrency violation detected") # deadlock
    # Temporary solution before we have gc transition support in codegen.
    # This could mess up gc state when we add codegen support.
    gc_state = ccall(:jl_gc_safe_enter, Int8, ())
    ccall(:uv_mutex_lock, Cvoid, (Ptr{Cvoid},), m)
    ccall(:jl_gc_safe_leave, Cvoid, (Int8,), gc_state)
    m.ownertid = threadid()
    return
end

function trylock(m::Mutex)
    m.ownertid == threadid() && error("concurrency violation detected") # deadlock
    r = ccall(:uv_mutex_trylock, Cint, (Ptr{Cvoid},), m)
    if r == 0
        m.ownertid = threadid()
    end
    return r == 0
end

function unlock(m::Mutex)
    m.ownertid == threadid() || error("concurrency violation detected")
    m.ownertid = 0
    ccall(:uv_mutex_unlock, Cvoid, (Ptr{Cvoid},), m)
    return
end

function islocked(m::Mutex)
    return m.ownertid != 0
end

"""
    ReentrantLockMT()

A thread-safe version of [`ReentrantLock`](@ref).
"""
const ReentrantLockMT = GenericReentrantLock{TatasLock}

"""
    ConditionMT([lock-mt])

A thread-safe version of [`Condition`](@ref).
"""
const ConditionMT = GenericCondition{ReentrantLockMT}

"""
    EventMT()

A thread-safe version of [`Event`](@ref).
"""
const EventMT = GenericEvent{ReentrantLockMT}

"""
Special note for [`Threads.ConditionMT`](@ref):

The caller must be holding the [`lock`](@ref) that owns `c` before calling this method.
The calling task will be blocked until some other task wakes it,
usually by calling [`notify`](@ref)` on the same ConditionMT object.
The lock will be atomically released when blocking (even if it was locked recursively),
and will be reacquired before returning.
"""
wait(c::ConditionMT)
