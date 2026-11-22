# Input and output without libuv: the streams that compiled programs read and write, and their contexts.
#
# Julia's standard streams are libuv streams, which need the Julia runtime; a program has libc's (`FILE*`), as `IO`s
# that implement the interface that Base's own reading and writing code is written against. Files are the same kind of
# stream. An `IOContext` is a stream with its properties in its type, so that what `show` asks of it is known when
# compiling. What is written to these streams is in printing.jl.

## Streams of libc
#
# Julia's `stdout`, `stderr` and `stdin` are libuv streams, which need the Julia runtime. Here they are streams of libc
# (`FILE*`), as an `IO` that implements the interface that Base's `print`, `show`, `readline`, and so on are written
# against, so that all of Base's own code for writing and reading things works on it unchanged.

using StaticTools: FILE, stdinp, stdoutp, stderrp, fwrite, fread!, getc

"""
    StaticIO{S}

An `IO` for one of the standard streams of libc, `S` being `:stdin`, `:stdout` or `:stderr`.
There is no buffering besides that of libc (which flushes the streams when the program exits).

These are the streams to use in compiled code instead of `stdin`, `stdout` and `stderr` of Base,
which are globals of the abstract type `IO`, so that calls using them can't be resolved when
compiling: [`STDIN`](@ref), [`STDOUT`](@ref) and [`STDERR`](@ref). `print(x)`, `println(x)` and
`show(x)`, which write to `stdout`, do use [`STDOUT`](@ref).
"""
struct StaticIO{S} <: IO end

"The standard input of libc, an [`StaticIO`](@ref); use instead of `stdin`."
const STDIN = StaticIO{:stdin}()

"The standard output of libc, an [`StaticIO`](@ref); use instead of `stdout`."
const STDOUT = StaticIO{:stdout}()

"The standard error of libc, an [`StaticIO`](@ref); use instead of `stderr`."
const STDERR = StaticIO{:stderr}()

"""
    StaticFile

A file opened with `open` (see "Files" below). Like the standard streams, it is a `FILE*` of libc, so the
methods that read and write are the same for the two.
"""
mutable struct StaticFile <: IO
    fp::Ptr{FILE}
end

"The streams of libc: [`StaticIO`](@ref) and [`StaticFile`](@ref)"
const LibcStream = Union{StaticIO, StaticFile}

# the libc `FILE*` of the stream (a file that has been closed has no `FILE*`: using it is an error, as in Julia, and not
# a call of libc with a null pointer)
function filepointer(f::StaticFile)
    fp = f.fp
    fp == C_NULL && throw(ErrorException("stream is closed"))
    return fp
end

filepointer(::StaticIO{:stdin}) = stdinp()

filepointer(::StaticIO{:stdout}) = stdoutp()

filepointer(::StaticIO{:stderr}) = stderrp()

Base.isopen(::StaticIO) = true

Base.close(::StaticIO) = nothing # the standard streams are not ours to close

Base.isreadable(::StaticIO{S}) where {S} = S === :stdin

Base.iswritable(::StaticIO{S}) where {S} = S !== :stdin

## Writing

# (a write or a flush that libc reports as failed is an error, as it is in Julia: a full disk, a closed pipe. Without
# this, what could not be written is lost without a word.)
write_error() = throw(ErrorException("error writing to a stream (the write or flush of libc failed)"))

function Base.unsafe_write(io::LibcStream, p::Ptr{UInt8}, n::UInt)
    written = Int(fwrite(filepointer(io), p, 1, Int64(n)))
    written == Int(n) || write_error()
    return written
end

function Base.write(io::LibcStream, x::UInt8)
    status = @symbolcall fputc(Int32(x)::Int32, filepointer(io)::Ptr{FILE})::Int32
    status < 0 && write_error()
    return 1
end

function Base.flush(io::LibcStream)
    status = @symbolcall fflush(filepointer(io)::Ptr{FILE})::Int32
    status == 0 || write_error()
    return nothing
end

## Reading

function Base.read(io::LibcStream, ::Type{UInt8})
    c = getc(filepointer(io))
    c < 0 && throw(EOFError())
    return UInt8(c)
end

function Base.eof(io::LibcStream)
    fp = filepointer(io)
    c = getc(fp)
    c < 0 && return true
    @symbolcall ungetc(c::Int32, fp::Ptr{FILE})::Int32
    return false
end

# the next byte, without reading it: libc can put back a character (the generic one uses `mark` and `reset`)
function Base.peek(io::LibcStream, ::Type{UInt8})
    fp = filepointer(io)
    c = getc(fp)
    c < 0 && throw(EOFError())
    @symbolcall ungetc(c::Int32, fp::Ptr{FILE})::Int32
    return UInt8(c)
end

function Base.unsafe_read(io::LibcStream, p::Ptr{UInt8}, n::UInt)
    got = fread!(p, filepointer(io), 1, Int64(n))
    got == Int64(n) || throw(EOFError())
    return nothing
end

## Files
#
# `open` gives a [`StaticFile`](@ref) (above), an `IO` like the standard streams, so what Base has for
# reading and writing an `IO` works with it: `read(io, String)`, `readline`, `readlines`, `eachline`, `println(io, x)`,
# `write`, `@printf(io, ...)`, `open(f, path, mode)`, `read(path, String)`, `write(path, x)`, ...

using StaticTools: fopen, fclose, ftell, fseek, frewind, SEEK_SET, SEEK_CUR, SEEK_END

# A `String` is terminated by a NUL, as C wants it, and a `SubString` is not
function open_file(path::AbstractString, mode::AbstractString)
    path, mode = String(path), String(mode)
    fp = GC.@preserve path mode fopen(pointer(path), pointer(mode))
    fp == C_NULL && throw(ErrorException(string("could not open file ", path)))
    return StaticFile(fp)
end

"""
    open(path, [mode = "r"]; read, write, create, truncate, append, lock) -> StaticFile

Open the file `path`, as a `StaticFile`. `mode` is a C `fopen` mode (`"r"`, `"w"`, `"a"`, `"r+"`, ...: opened with `fopen`). The
keywords are those of Base's `open` (`read = true`, `append = true`, `create = false`, ...), with the same meaning for each
combination: the file is opened with `open` of the system, with the flags that they say, and then given to libc as a stream
(`fdopen`). `lock` is accepted and does nothing (there is one thread). Close it with `close`; `open(f, path, ...)` does, after
calling `f(io)`.
"""
@device_override Base.open(path::AbstractString, mode::AbstractString) = open_file(path, mode)

# the flags of `open` of each system (the access is `O_RDONLY` 0, `O_WRONLY` 1 or `O_RDWR` 2)
@static if Sys.isapple()
    const O_APPEND, O_CREAT, O_TRUNC = Cint(0x8), Cint(0x200), Cint(0x400)
else
    const O_APPEND, O_CREAT, O_TRUNC = Cint(0x400), Cint(0x40), Cint(0x200)
end

# The file as Base opens it: the flags are those that Base works out from the keywords (`Base.open_flags`), as `open` of the
# system takes them, and the stream is made from the descriptor with the mode that its access is (what is there is not
# truncated by `fdopen`)
function open_file_with_flags(path::AbstractString, read::Bool, write::Bool, create::Bool, truncate::Bool, append::Bool)
    path = String(path)
    access = read && write ? Cint(2) : write ? Cint(1) : Cint(0)
    flags = access | (create ? O_CREAT : Cint(0)) | (truncate ? O_TRUNC : Cint(0)) | (append ? O_APPEND : Cint(0))
    fd = GC.@preserve path ccall(:open, Cint, (Cstring, Cint, Base.Cmode_t...), path, flags, Base.Cmode_t(0o666))
    fd < 0 && throw(ErrorException(string("could not open file ", path)))
    mode = append ? (read ? "a+" : "a") : read && write ? "r+" : write ? "w" : "r"
    fp = GC.@preserve mode ccall(:fdopen, Ptr{FILE}, (Cint, Cstring), fd, mode)
    if fp == C_NULL
        ccall(:close, Cint, (Cint,), fd)
        throw(ErrorException(string("could not open file ", path)))
    end
    return StaticFile(fp)
end

@device_override function Base.open(path::AbstractString; lock = true, read::Union{Bool,Nothing} = nothing, write::Union{Bool,Nothing} = nothing,
                                    create::Union{Bool,Nothing} = nothing, truncate::Union{Bool,Nothing} = nothing, append::Union{Bool,Nothing} = nothing)
    f = Base.open_flags(; read, write, create, truncate, append)
    return open_file_with_flags(path, f.read, f.write, f.create, f.truncate, f.append)
end

function Base.close(f::StaticFile)
    fp = f.fp
    f.fp = C_NULL
    # (`fclose` writes what is buffered, and reports if that failed: the file is closed either way)
    fp == C_NULL || fclose(fp) == 0 || write_error()
    return nothing
end

Base.isopen(f::StaticFile) = f.fp != C_NULL

Base.isreadable(f::StaticFile) = isopen(f)

Base.iswritable(f::StaticFile) = isopen(f)

## Position

Base.position(f::StaticFile) = Int(ftell(filepointer(f)))

Base.seek(f::StaticFile, n::Integer) = (fseek(filepointer(f), Int64(n), SEEK_SET); f)

Base.seekstart(f::StaticFile) = (fseek(filepointer(f), Int64(0), SEEK_SET); f)

Base.seekend(f::StaticFile) = (fseek(filepointer(f), Int64(0), SEEK_END); f)

Base.skip(f::StaticFile, n::Integer) = (fseek(filepointer(f), Int64(n), SEEK_CUR); f)

function Base.filesize(f::StaticFile)
    fp = filepointer(f)
    here = ftell(fp)
    fseek(fp, Int64(0), SEEK_END)
    size = ftell(fp)
    fseek(fp, here, SEEK_SET)
    return Int(size)
end

# what is left to read, which lets `read(io)` allocate once
Base.bytesavailable(f::StaticFile) = filesize(f) - position(f)

## Writing and reading with `write`, `readline`, `readlines` and `eachline`
##
## Those of Base, for a file name or without a stream, which has the stream from `stdin` (the global of the abstract
## type `IO`), are written with keyword arguments (`keep`, `cancel`), and in terms of closures (`eachline` stores the
## function that closes the file in a field of the abstract type `Function`), which can't be resolved when compiling.
## These do the same, with `keep` where Base has it.

# `write(io, xs...)` loops over its arguments, which have different types (as `print`, see `base.jl`)
write_all(io) = 0

write_all(io, x, rest...) = write(io, x) + write_all(io, rest...)

@device_override Base.write(io::IO, x1, x2, xs...) = write_all(io, x1, x2, xs...)

@device_override function Base.write(path::AbstractString, x, xs...)
    io = open_file(path, "w")
    n = write_all(io, x, xs...)
    close(io)
    return n
end

function readlines_of(io::IO)
    lines = String[]
    while !eof(io)
        push!(lines, readline(io))
    end
    return lines
end

@device_override Base.readlines(io::IO) = readlines_of(io)

@device_override Base.readlines() = readlines_of(STDIN)

@device_override function Base.readlines(path::AbstractString)
    io = open_file(path, "r")
    lines = readlines_of(io)
    close(io)
    return lines
end

@device_override Base.readline() = readline(STDIN)

@device_override function Base.readline(path::AbstractString)
    io = open_file(path, "r")
    line = readline(io)
    close(io)
    return line
end

"""
    StaticEachLine

What `eachline` is in compiled code: an iterator of the lines of a stream (which is closed at the end if
it is of a file that `eachline` opened).
"""
struct StaticEachLine{IOT<:IO}
    stream::IOT
    owned::Bool
end

function Base.iterate(itr::StaticEachLine, state = nothing)
    if eof(itr.stream)
        itr.owned && close(itr.stream)
        return nothing
    end
    return readline(itr.stream), nothing
end

Base.eltype(::Type{<:StaticEachLine}) = String

Base.IteratorSize(::Type{<:StaticEachLine}) = Base.SizeUnknown()

@device_override Base.eachline() = StaticEachLine(STDIN, false)

@device_override Base.eachline(io::IO) = StaticEachLine(io, false)

@device_override Base.eachline(path::AbstractString) = StaticEachLine(open_file(path, "r"), true)

# The size of a file, by opening it (Base uses `stat`, which is not available)
@device_override function Base.filesize(path::AbstractString)
    io = open_file(path, "r")
    size = filesize(io)
    close(io)
    return size
end

## Streams with properties: `IOContext`
#
# `show` asks for what to show and how.
#
# In Base the properties are an `ImmutableDict` of `Any`s, which the code that asks (`get(io, :compact, false)::Bool`)
# looks in when the program runs. Here they are in the *type* of the stream (`ContextIO{S,K,V}` has the names in the
# tuple `K`, and the values in `V`, a tuple type of `Val`s: a tuple of the values would not do, as a type can't be a
# value in a tuple that is a parameter of a type), so that asking is a constant, and what depends on it is decided when
# compiling. That is why the value of a property has to be known then (a `Bool`, a number, a type, a tuple of those):
# `IOContext(io, :compact => flag)` with a `flag` that is only known when the program runs is a call that can't be
# resolved (compiling says so). Properties that are not kept: `:SHOWN_SET` (the containers that contain themselves,
# which are not detected) and `:module` (the names of types are made when compiling, see printing.jl).

"""
    ContextIO{S,K,V}

The stream `S` with the properties `K` (names) and `V` (their values, as a `Tuple` type of `Val`s) of its context, which are in the type, so that they are known when compiling.
(Made by `IOContext(io, :name => value, ...)`, as in Base.)
"""
struct ContextIO{S<:IO,K,V} <: IO
    io::S
end

Base.unsafe_write(io::ContextIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.io, p, n)

Base.write(io::ContextIO, x::UInt8) = write(io.io, x)

Base.flush(io::ContextIO) = flush(io.io)

Base.isopen(io::ContextIO) = isopen(io.io)

Base.iswritable(io::ContextIO) = iswritable(io.io)

Base.lock(::ContextIO) = nothing

Base.unlock(::ContextIO) = nothing

"""
    BufIO

The stream that `sprint` and `repr` write to when compiled: an `IOBuffer`, which is not one of the streams
that the methods of printing.jl are for, inside a type that is.
"""
struct BufIO <: IO
    buf::IOBuffer
end

Base.unsafe_write(io::BufIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.buf, p, n)

Base.write(io::BufIO, x::UInt8) = write(io.buf, x)

Base.flush(::BufIO) = nothing

Base.isopen(io::BufIO) = isopen(io.buf)

Base.iswritable(::BufIO) = true

Base.lock(::BufIO) = nothing

Base.unlock(::BufIO) = nothing

# the streams that the methods of printing.jl and of this section are for
const ShowStream = Union{LibcStream, ContextIO, BufIO}

# the stream that is written to, without its context
base_io(io::ContextIO) = io.io

base_io(io) = io

## Asking for properties

Base.get(::ShowStream, key::Symbol, default) = default # (no properties)

# (`S<:IO` as in the type: without it the method is not as specific as one for `Union{..., ContextIO, ...}`, and is not
# the one that is called)
@generated function Base.get(io::ContextIO{S,K,V}, key::Symbol, default) where {S<:IO,K,V}
    body = :default
    for i in length(K):-1:1
        # (the value is quoted: one that is a `Symbol` would be the name of a variable in the code)
        body = :(key === $(QuoteNode(K[i])) ? $(QuoteNode(V.parameters[i].parameters[1])) : $body)
    end
    return body
end

@generated Base.haskey(io::ContextIO{S,K,V}, key::Symbol) where {S<:IO,K,V} = :(key in $K)

Base.getindex(io::ContextIO, key::Symbol) = haskey(io, key) ? get(io, key, nothing) : throw(KeyError(key))

Base.displaysize(io::ContextIO) = haskey(io, :displaysize) ? io[:displaysize]::Tuple{Int,Int} : displaysize(io.io)::Tuple{Int,Int}

# what the context of the stream knows about the type of what is shown: `:typeinfo`, as in Base (`Any` for no
# information)
typeinfo_of(io::ShowStream) = get(io, :typeinfo, Any)

# the same, from the type of the stream (for the `@generated` functions)
typeinfo_type(::Type{<:ContextIO{S,K,V}}) where {S,K,V} = (i = findfirst(==(:typeinfo), K); i === nothing ? Any : V.parameters[i].parameters[1])

typeinfo_type(::Type) = Any

## Making streams with properties

# the same stream with the property `key` of the value `value` (the other properties as they are)
@generated function with_property(io::S, ::Val{key}, ::Val{value}) where {S<:ShowStream, key, value}
    if S <: ContextIO
        base, K, V = S.parameters
        keys, values = Any[K...], Any[V.parameters...]
        stream = :(io.io)
    else
        base, keys, values = S, Any[], Any[]
        stream = :io
    end
    i = findfirst(==(key), keys)
    if key === :typeinfo && value === Any
        # (`Any` is what the property is when there is none: the same, and a smaller type, without a `Val{Any}`)
        i === nothing || (deleteat!(keys, i); deleteat!(values, i))
    elseif i === nothing
        push!(keys, key)
        push!(values, Val{value})
    else
        values[i] = Val{value}
    end
    isempty(keys) && return :(base_io(io))
    return :(ContextIO{$base, $(Tuple(keys)), $(Tuple{values...})}($stream))
end

# (what is not kept is not made a property: its value is not one that can be in a type, or is not used)
const IGNORED_PROPERTIES = (:SHOWN_SET, :module)

# (`@constprop :aggressive`: the name and the value of the property are known where `IOContext` is called, and have to
# be known in the methods, to make the type)
Base.@constprop :aggressive @inline property_context(io::ShowStream, ::Val{key}, value) where {key} = key in IGNORED_PROPERTIES ? io : with_property(io, Val(key), Val(value))

Base.@constprop :aggressive @inline Base.IOContext(io::ShowStream, p::Pair{Symbol}) = property_context(io, Val(p.first), p.second)

Base.@constprop :aggressive @inline Base.IOContext(io::ShowStream, p::Pair{Symbol}, ps::Pair{Symbol}...) = IOContext(IOContext(io, p), ps...)

# (the properties of another stream: those of the stream `context`)
Base.IOContext(io::ShowStream, ::ContextIO{S,K,V}) where {S<:IO,K,V} = ContextIO{typeof(base_io(io)),K,V}(base_io(io))

Base.IOContext(io::ShowStream, ::ShowStream) = io

# Base shows some things into a buffer first, with the context of the stream that it shows to (`IOContext(IOBuffer(),
# io)`, as the imaginary part of a `Complex` is): the buffer is written to through a `BufIO`, so that what is written to
# it is shown by the methods that are for those streams (and the context is static)
@device_override Base.IOContext(io::IOBuffer, context::ShowStream) = IOContext(BufIO(io), context)

typeinfo_io(io::ShowStream, ::Type{T}) where {T} = with_property(io, Val(:typeinfo), Val(T))
