# What a program for Windows does differently from one for macOS or Linux, for files, directories, the environment and the small calls of the system: the functions that the overrides of `filesystem.jl`, `io.jl` and
# `system.jl` call when the program is made for Windows (`if target_windows()`, a constant when the program is compiled, so the other branch is not in the program).
#
# * Paths are UTF-8 in Julia, and what the C library of Windows takes by default is the code page of the system, so the functions of it that take a path are the wide ones (`_wfopen`, `_wopen`, `_wstat64`, `_wmkdir`, ...), given
#   UTF-16 (`wide_cstring`, and `narrow_string` for what they give).
# * What Windows does with files that C does not: the streams are binary (a `FILE*` is in text mode by default, which writes a line feed as a carriage return and a line feed), the offsets are 64 bits (`ftell` and `fseek` take
#   a `long`, which is 32), a file that is renamed over another one replaces it (`MoveFileExW`, as Julia's does), and a directory is read with `FindFirstFileW` (there is no `readdir`).
# * The errors of the C library are in `errno` (the numbers are those of Windows's C library: `ENOTEMPTY` is 41), and those of Windows's own functions are `GetLastError()`, which `windows_errno` turns into the `errno` that the
#   C library would have, so that the errors of a program are the same wherever they come from.
# * What is not here: links (`symlink`, `readlink`: they need a privilege), `mmap`, locks, permissions that are more than whether the file can be written, and paths that are longer than 260 characters (they need the prefix `\\?\`).
#
# (An argument of `@symbolcall` is the value that is given, and `::T` says the type that the function has: the value has to be of that type, `Int32(0)::Int32` and not `0::Int32`, or the call is a type error that always throws.)
# The functions of Windows are called with `@symbolcall`, the symbol of the function and its types, which does not look at the list of the functions of the C library (`LIBC_FUNCTIONS`): all of these are in the libraries that a
# program for Windows is linked with (the C library `msvcrt`, `kernel32` and `advapi32`).

## Strings: UTF-8 and UTF-16

# The text as the wide functions take it: UTF-16 and a NUL after it. What is not valid UTF-8 is `U+FFFD`.
function wide_cstring(s::AbstractString)
    s = String(s)
    out = UInt16[]
    for c in s
        u = isvalid(c) ? UInt32(c) : UInt32(0xfffd)
        if u < 0x10000
            push!(out, u % UInt16)
        else
            u -= 0x10000
            push!(out, (0xd800 + (u >> 10)) % UInt16)
            push!(out, (0xdc00 + (u & 0x3ff)) % UInt16)
        end
    end
    push!(out, UInt16(0))
    return out
end

# The text that the wide functions give: the `n` units that `p` points to, or up to the NUL; UTF-8. A half of a pair of surrogates that has no other half is `U+FFFD`.
function narrow_string(p::Ptr{UInt16}, n::Int = -1)
    bytes = UInt8[]
    i = 1
    while n < 0 || i <= n
        u = unsafe_load(p, i)
        n < 0 && u == 0 && break
        i += 1
        cp = UInt32(u)
        if 0xd800 <= u < 0xdc00
            v = (n < 0 || i <= n) ? unsafe_load(p, i) : UInt16(0)
            if 0xdc00 <= v < 0xe000
                i += 1
                cp = 0x10000 + ((UInt32(u) - 0xd800) << 10) + (UInt32(v) - 0xdc00)
            else
                cp = 0xfffd
            end
        elseif 0xdc00 <= u < 0xe000
            cp = 0xfffd
        end
        if cp < 0x80
            push!(bytes, cp % UInt8)
        elseif cp < 0x800
            push!(bytes, (0xc0 | (cp >> 6)) % UInt8)
            push!(bytes, (0x80 | (cp & 0x3f)) % UInt8)
        elseif cp < 0x10000
            push!(bytes, (0xe0 | (cp >> 12)) % UInt8)
            push!(bytes, (0x80 | ((cp >> 6) & 0x3f)) % UInt8)
            push!(bytes, (0x80 | (cp & 0x3f)) % UInt8)
        else
            push!(bytes, (0xf0 | (cp >> 18)) % UInt8)
            push!(bytes, (0x80 | ((cp >> 12) & 0x3f)) % UInt8)
            push!(bytes, (0x80 | ((cp >> 6) & 0x3f)) % UInt8)
            push!(bytes, (0x80 | (cp & 0x3f)) % UInt8)
        end
    end
    return String(bytes)
end
narrow_string(buffer::Vector{UInt16}) = GC.@preserve buffer narrow_string(pointer(buffer))

# a path without the separators at its end, which Windows's functions do not take on a directory (`stat("dir/")`), except that of a root (`C:\`, `/`)
function windows_trimmed(path::AbstractString)
    s = String(path)
    n = lastindex(s)
    while n > 1 && (s[n] == '/' || s[n] == '\\') && !(n == 3 && s[2] == ':')
        n = prevind(s, n)
    end
    return n == lastindex(s) ? s : s[1:n]
end

## Errors

# `GetLastError()` of a call of Windows, as the `errno` that the C library has for it (`ENOENT` for what is not there, ...)
function windows_errno(code::UInt32)
    code == 2 || code == 3 || code == 15 || code == 18 || code == 206 ? E_NOENT : # (not found: the file, the path, the drive, no more files, a name that is too long)
    code == 5 || code == 19 || code == 32 || code == 33 ? E_ACCES : # (access denied, write protected, in use by another process, locked)
    code == 80 || code == 183 ? E_EXIST : # (exists)
    code == 17 ? E_XDEV :
    code == 145 ? errno_enotempty() :
    code == 267 ? E_NOTDIR :
    code == 87 || code == 123 || code == 161 ? E_INVAL : # (a parameter, a name or a path that is not valid)
    code == 4 ? 24 : # (too many open files: `EMFILE`)
    code == 112 ? 28 : # (the disk is full: `ENOSPC`)
    5 # (`EIO`)
end

@inline windows_last_error() = @symbolcall GetLastError()::UInt32

# a call of Windows failed: its error is `errno` as the C library would have it, where the functions of the overrides read it
function windows_failed()
    unsafe_store!(errno_pointer(), Cint(windows_errno(windows_last_error())))
    return Cint(-1)
end

@inline windows_errno_pointer() = @symbolcall _errno()::Ptr{Cint}

## Files and directories

# (the status of each is that of the function of the C library that it stands for: 0 for success, and the error in `errno`)

win_access(path::AbstractString) = (w = wide_cstring(windows_trimmed(path)); GC.@preserve w Cint(@symbolcall _waccess(pointer(w)::Ptr{UInt16}, Int32(0)::Int32)::Int32))

win_mkdir(path::AbstractString) = (w = wide_cstring(path); GC.@preserve w Cint(@symbolcall _wmkdir(pointer(w)::Ptr{UInt16})::Int32))

win_rmdir(path::AbstractString) = (w = wide_cstring(path); GC.@preserve w Cint(@symbolcall _wrmdir(pointer(w)::Ptr{UInt16})::Int32))

win_unlink(path::AbstractString) = (w = wide_cstring(path); GC.@preserve w Cint(@symbolcall _wunlink(pointer(w)::Ptr{UInt16})::Int32))

win_chdir(path::AbstractString) = (w = wide_cstring(path); GC.@preserve w Cint(@symbolcall _wchdir(pointer(w)::Ptr{UInt16})::Int32))

# (a file can be written, or it is read-only: the only thing that Windows has of the mode)
windows_chmod_mode(mode::Integer) = Int32(0x100) | ((mode & 0o222) != 0 ? Int32(0x80) : Int32(0))
win_chmod(path::AbstractString, mode::Integer) = (w = wide_cstring(path); GC.@preserve w Cint(@symbolcall _wchmod(pointer(w)::Ptr{UInt16}, windows_chmod_mode(mode)::Int32)::Int32))

# a file or a directory is moved to the name, which another file that is there is replaced by (`MOVEFILE_REPLACE_EXISTING`, 1), and that can be on another volume (`MOVEFILE_COPY_ALLOWED`, 2)
function win_rename(oldpath::AbstractString, newpath::AbstractString)
    old, new = wide_cstring(oldpath), wide_cstring(newpath)
    ok = GC.@preserve old new @symbolcall MoveFileExW(pointer(old)::Ptr{UInt16}, pointer(new)::Ptr{UInt16}, UInt32(3)::UInt32)::Int32
    return ok != 0 ? Cint(0) : windows_failed()
end

function windows_pwd()
    buffer = Vector{UInt16}(undef, 4096)
    p = GC.@preserve buffer @symbolcall _wgetcwd(pointer(buffer)::Ptr{UInt16}, Int32(4096)::Int32)::Ptr{UInt16}
    p == C_NULL && fs_error("pwd", "")
    return narrow_string(buffer)
end

# the full path, where the file is (Windows's `realpath`: the links are not resolved, as it has none here)
function windows_realpath(path::String)
    win_access(path) == 0 || fs_error("realpath", path)
    w = wide_cstring(path)
    buffer = Vector{UInt16}(undef, 4096)
    n = GC.@preserve w buffer @symbolcall GetFullPathNameW(pointer(w)::Ptr{UInt16}, UInt32(4096)::UInt32, pointer(buffer)::Ptr{UInt16}, Ptr{UInt16}(0)::Ptr{UInt16})::UInt32
    (n == 0 || n >= 4096) && (windows_failed(); fs_error("realpath", path))
    return narrow_string(buffer)
end

## `stat`: `struct _stat64` of the C library: the device (4 bytes) at 0, the inode (2) at 4, the mode (2) at 6, the number of links (2) at 8, the user and the group (2 each) at 10 and 12, the device of a special file (4) at 16,
## the size (8) at 24, and the times of access, modification and creation (8 each) at 32, 40 and 48: seconds, from 1970. Of the rest what libuv gives is made: a block of 4096 bytes, and the number of blocks of 512.

windows_stat_fields(path::String, buf::Vector{UInt8}) =
    Base.Filesystem.StatStruct(path, UInt(load_at(UInt32, buf, 0)), UInt(0), UInt(load_at(UInt16, buf, 6)), Int(max(load_at(Int16, buf, 8), Int16(0))), UInt(0), UInt(0), UInt(load_at(UInt32, buf, 16)),
        load_at(Int64, buf, 24), Int64(4096), (load_at(Int64, buf, 24) + 511) ÷ 512, Float64(load_at(Int64, buf, 40)), Float64(load_at(Int64, buf, 48)), Int32(0))

function windows_stat_struct(path::String)
    w = wide_cstring(windows_trimmed(path))
    buf = zeros(UInt8, 64)
    r = GC.@preserve w buf @symbolcall _wstat64(pointer(w)::Ptr{UInt16}, pointer(buf)::Ptr{UInt8})::Int32
    # (the code is the one of libuv, which is the negative of the number of the system)
    r != 0 && return Base.Filesystem.StatStruct(path, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0.0, Int32(-unsafe_load(errno_pointer())))
    return windows_stat_fields(path, buf)
end

## Directories are read with `FindFirstFileW`, which gives `WIN32_FIND_DATAW`: the name is at 44, in 260 units of UTF-16

function windows_readdir_names(dir::String)
    pattern = string(windows_trimmed(dir), "\\*")
    w = wide_cstring(pattern)
    data = zeros(UInt8, 592)
    names = String[]
    GC.@preserve w data begin
        handle = @symbolcall FindFirstFileW(pointer(w)::Ptr{UInt16}, pointer(data)::Ptr{UInt8})::Int
        if handle == -1 # (INVALID_HANDLE_VALUE)
            windows_failed()
            fs_error("readdir", dir)
        end
        while true
            name = narrow_string(Ptr{UInt16}(pointer(data) + 44))
            (name == "." || name == "..") || push!(names, name)
            (@symbolcall FindNextFileW(handle::Int, pointer(data)::Ptr{UInt8})::Int32) == 0 && break
        end
        @symbolcall FindClose(handle::Int)::Int32
    end
    return names
end

## Where things are, and temporary files

# (the first of `TMP`, `TEMP` and the home directory, as `GetTempPathW` has it, and the directory of the system: without the separator at its end)
function windows_tempdir()
    buffer = Vector{UInt16}(undef, 1024)
    n = GC.@preserve buffer @symbolcall GetTempPathW(UInt32(1024)::UInt32, pointer(buffer)::Ptr{UInt16})::UInt32
    (n == 0 || n >= 1024) && return "C:\\Windows\\Temp"
    return windows_trimmed(narrow_string(pointer(buffer), Int(n)))
end

# bytes from the system (`SystemFunction036`, which is `RtlGenRandom`)
function windows_random_bytes!(p::Ptr{UInt8}, n::Int)
    n == 0 && return true
    ok = @symbolcall SystemFunction036(p::Ptr{UInt8}, UInt32(n)::UInt32)::UInt8
    return ok != 0
end

# a name that is made of the prefix and six characters of the system's choice, as `mkstemp` makes one
function windows_temp_name(prefix::String)
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    raw = zeros(UInt8, 6)
    GC.@preserve raw windows_random_bytes!(pointer(raw), 6) || error("could not get entropy from the system")
    suffix = UInt8[UInt8(chars[1 + Int(b) % 62]) for b in raw]
    return string(prefix, String(suffix))
end

# a name that no file has
function windows_tempname(parent::String)
    for _ in 1:100
        path = windows_temp_name(joinpath(parent, "jl_"))
        win_access(path) == 0 || return path
    end
    fs_error("tempname", parent, E_EXIST)
end

# a file that is made, which no other had: opened for reading and writing (binary), as a stream
function windows_mktemp(parent::String)
    for _ in 1:100
        path = windows_temp_name(joinpath(parent, "jl_"))
        w = wide_cstring(path)
        # (`_O_RDWR` 2, `_O_CREAT` 0x100, `_O_EXCL` 0x400 and `_O_BINARY` 0x8000; `_S_IREAD | _S_IWRITE`)
        fd = GC.@preserve w @symbolcall _wopen(pointer(w)::Ptr{UInt16}, Int32(0x8502)::Int32, Int32(0x180)::Int32)::Int32
        if fd >= 0
            mode = "r+b"
            fp = GC.@preserve mode @symbolcall _fdopen(fd::Int32, pointer(mode)::Ptr{UInt8})::Ptr{FILE}
            fp == C_NULL && fs_error("mktemp", path)
            return path, StaticFile(fp)
        end
        unsafe_load(errno_pointer()) == E_EXIST || fs_error("mktemp", path)
    end
    fs_error("mktemp", parent, E_EXIST)
end

# a directory that is made
function windows_mktempdir(parent::String, prefix::String)
    for _ in 1:100
        path = windows_temp_name(joinpath(parent, prefix))
        win_mkdir(path) == 0 && return path
        unsafe_load(errno_pointer()) == E_EXIST || fs_error("mktempdir", path)
    end
    fs_error("mktempdir", parent, E_EXIST)
end

## The environment: the wide functions of the C library (`_wgetenv`, `_wputenv_s`, where a value that is empty removes the variable)

function windows_getenv(name::AbstractString)
    w = wide_cstring(name)
    p = GC.@preserve w @symbolcall _wgetenv(pointer(w)::Ptr{UInt16})::Ptr{UInt16}
    return p == C_NULL ? nothing : narrow_string(p)
end

function windows_setenv(name::AbstractString, value::AbstractString)
    wn, wv = wide_cstring(name), wide_cstring(value)
    return GC.@preserve wn wv Cint(@symbolcall _wputenv_s(pointer(wn)::Ptr{UInt16}, pointer(wv)::Ptr{UInt16})::Int32)
end

## Files opened as streams: the mode of `fopen` has `b` (binary), and the flags of `_wopen` have `_O_BINARY`

windows_binary_mode(mode::AbstractString) = occursin('b', mode) ? String(mode) : string(mode, "b")

function windows_open_file(path::String, mode::String)
    wpath, wmode = wide_cstring(path), wide_cstring(windows_binary_mode(mode))
    fp = GC.@preserve wpath wmode @symbolcall _wfopen(pointer(wpath)::Ptr{UInt16}, pointer(wmode)::Ptr{UInt16})::Ptr{FILE}
    fp == C_NULL && throw(ErrorException(string("could not open file ", path)))
    return StaticFile(fp)
end

# (`flags` are the flags of `_wopen` that are not `_O_BINARY`, which is added)
function windows_open_file_with_flags(path::String, flags::Cint, mode::String)
    w = wide_cstring(path)
    fd = GC.@preserve w @symbolcall _wopen(pointer(w)::Ptr{UInt16}, (flags | Cint(0x8000))::Int32, Int32(0x180)::Int32)::Int32
    fd < 0 && throw(ErrorException(string("could not open file ", path)))
    binary = windows_binary_mode(mode)
    fp = GC.@preserve binary @symbolcall _fdopen(fd::Int32, pointer(binary)::Ptr{UInt8})::Ptr{FILE}
    if fp == C_NULL
        @symbolcall close(fd::Int32)::Int32
        throw(ErrorException(string("could not open file ", path)))
    end
    return StaticFile(fp)
end
