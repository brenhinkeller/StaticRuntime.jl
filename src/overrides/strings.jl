# Strings and characters: building strings (`string` of characters, strings and symbols), `@assert` messages, CRC32c,
# `LazyString`, and the properties of characters (category, width, case) without utf8proc. Symbols as strings are in
# symbols.jl, and `string` of values of other types (`print_to_string`) in printing.jl.

# `string(chars, strings, symbols...)` (`_string`) loops over its arguments twice, the first time to add up their
# lengths and the second to copy them, again with arguments of different types: so recurse over them, as
# `print_to_string` does (printing.jl)
@device_override function Base._string(a::Union{Char, String, SubString{String}, Symbol}...)
    out = Base._string_n(string_size(a...))
    string_fill!(out, 1, a...)
    return out
end

string_size() = 0

string_size(v::Char, rest...) = ncodeunits(v) + string_size(rest...)

string_size(v::Union{String, SubString{String}}, rest...) = sizeof(v) + string_size(rest...)

string_size(v::Symbol, rest...) = symbol_length(v) + string_size(rest...)

string_fill!(out, offs) = nothing

function string_fill!(out, offs, v, rest...)
    offs += Base.__unsafe_string!(out, v, offs)
    return string_fill!(out, offs, rest...)
end

# `@assert cond "message $x"` (a message that is not a literal) makes the message with `_assert_tostring`, which is
# opaque to the compiler on purpose (`Core.compilerbarrier`), so it is a call on an `Any`. The message is a `String`,
# nearly always, and then there is nothing to do.
@device_override Base._assert_tostring(msg::String) = msg

# CRC-32C (Castagnoli, as the standard library `CRC32c` and the instructions of the processors have it), where Base
# calls `jl_crc32c`: one byte at a time, with a table. `crc` is the value of the end of the data before, as it is for
# the C function (it starts as 0), so it is turned about at the start and the end.
const CRC32C_TABLE = let table = Vector{UInt32}(undef, 256)
    for i in 0:255
        c = UInt32(i)
        for _ in 1:8
            c = (c & 1) != 0 ? (c >> 1) ⊻ 0x82f63b78 : c >> 1
        end
        table[i+1] = c
    end
    table
end

@device_override function Base.unsafe_crc32c(a, n, crc)
    c = ~convert(UInt32, crc) # (as `ccall` converts the arguments)
    holder = Base.cconvert(Ptr{UInt8}, a) # (what `ccall` makes of the argument: a pointer to the data of an array, a string, or a `Ref`)
    GC.@preserve holder begin
        p = Base.unsafe_convert(Ptr{UInt8}, holder)
        i = 0
        while i < n
            c = @inbounds(CRC32C_TABLE[((c ⊻ unsafe_load(p, i + 1)) & 0xff) + 1]) ⊻ (c >> 8)
            i += 1
        end
    end
    return ~c
end

# Base's methods of `_crc32c` for integers (and so for a `UUID`, by its `UInt128`) call `jl_crc32c` themselves, not
# `unsafe_crc32c`. (Only these types: an override is used over a method of Base that is more specific, so a wider one
# would take the place of the methods for strings, arrays and streams, which already end in `unsafe_crc32c`.)
@device_override function Base._crc32c(x::Union{UInt8,UInt16,UInt32,UInt64,UInt128}, crc::UInt32 = 0x00000000)
    r = Ref(x)
    return GC.@preserve r Base.unsafe_crc32c(Ptr{UInt8}(pointer_from_objref(r)), sizeof(x), crc)
end

## `LazyString`
#
# `lazy"..."` (what the messages of `SciMLLogging`, and of some other packages, are) keeps its parts in a field of the
# type `Tuple`, which is not a concrete type: what is in it, and where, is only known when the program runs, and there
# is no way to read the elements of a tuple of a type that is not known without the runtime. Code that makes such
# messages compiles (the messages are made, and kept as they are); one that is turned into a `String` (printed, ...) is
# an error when the program runs, which says so. (A string that was made before, `l.str`, is the one that is given.) The
# packages that make them make them for messages that are not shown by default (`SciMLLogging`).
#
# (Making the string from the types of the tuples that the program stores in the field, found as for any field of an
# abstract type, was tried: the messages of `SciMLLogging` have parts whose `print` does not compile, and every program
# that solves a differential equation was refused.)
@device_override function Base.String(l::Base.LazyString)
    old = @atomic :acquire l.str
    old === nothing || return old::String
    throw(ArgumentError("a lazy string (`lazy\"...\"`) is made into a string when the program runs, which a program can't do: its parts are a tuple whose types are not known when compiling"))
end

## Characters: Unicode properties without utf8proc
#
# Julia gets the properties of characters (their category, width, upper and lower case, ...) from the utf8proc library,
# which is part of libjulia. These are functions of the code point alone, so instead we tabulate them (as runs of code
# points with the same value), when this package is compiled, with the version of utf8proc of the Julia that it is
# compiled for. The tables are then data of the programs that use them, like any other constant.


"""
    RunTable{T}

The values of a function of the code points `0:0x10ffff`, as the first code point of each of the runs
of code points with the same value (`starts`), and the values (`values`) of the runs.
"""
struct RunTable{T}
    starts::Vector{UInt32}
    values::Vector{T}
end

# the value of the code point `cp`
@inline lookup(table::RunTable, cp::UInt32) = @inbounds table.values[searchsortedlast(table.starts, cp)]

function RunTable(f, ::Type{T}) where {T}
    starts = UInt32[]
    values = T[]
    for cp in UInt32(0):UInt32(0x10ffff)
        value = f(cp)::T
        if isempty(values) || @inbounds(values[end]) != value
            push!(starts, cp)
            push!(values, value)
        end
    end
    return RunTable{T}(starts, values)
end

"""
    BoolRunTable

A function of the code points that is `true` or `false`, as the first code point of each run: the runs alternate, so the
values are not kept (only whether the first is `true`). It is a fraction of the size of a [`RunTable`](@ref) of `Bool`s.
"""
struct BoolRunTable
    starts::Vector{UInt32}
    first::Bool
end

@inline lookup(table::BoolRunTable, cp::UInt32) = table.first ⊻ iseven(searchsortedlast(table.starts, cp))

function BoolRunTable(f)
    starts = UInt32[]
    last = nothing
    for cp in UInt32(0):UInt32(0x10ffff)
        value = f(cp)::Bool
        value === last && continue
        push!(starts, cp)
        last = value
    end
    # (`starts[1]` is 0: the code points are all in a run)
    return BoolRunTable(starts, f(UInt32(0)))
end

# the properties, by the functions of utf8proc that Base uses
const CATEGORY = RunTable(cp -> UInt8(Base.Unicode.category_code(cp)), UInt8)
const CHARWIDTH = RunTable(cp -> UInt8(@ccall utf8proc_charwidth(cp::UInt32)::Cint), UInt8)
const ISLOWER = BoolRunTable(cp -> !iszero(@ccall utf8proc_islower(cp::UInt32)::Cint))
const ISUPPER = BoolRunTable(cp -> !iszero(@ccall utf8proc_isupper(cp::UInt32)::Cint))
# (`isprint` is a test of the category, which is a table that is five times as large: this is what showing a string
# needs)
const ISPRINT = BoolRunTable(cp -> Base.Unicode.UTF8PROC_CATEGORY_LU <= Base.Unicode.category_code(cp) <= Base.Unicode.UTF8PROC_CATEGORY_ZS)
# (`isspace` is a test of the category too, of three categories, and it is asked of every `parse` of a number and every
# `strip`: a table of its own is a few bytes)
const ISSPACE = BoolRunTable(cp -> isvalid(Char, cp) && Base.isspace(Char(cp)))
# the case mappings, as how far the code point is moved: runs are long (`'a':'z'` all move by 32)
const TOLOWER = RunTable(cp -> Int32(@ccall(utf8proc_tolower(cp::UInt32)::UInt32)) - Int32(cp), Int32)
const TOUPPER = RunTable(cp -> Int32(@ccall(utf8proc_toupper(cp::UInt32)::UInt32)) - Int32(cp), Int32)
const TOTITLE = RunTable(cp -> Int32(@ccall(utf8proc_totitle(cp::UInt32)::UInt32)) - Int32(cp), Int32)

@inline mapped(c::Char, table::RunTable{Int32}) = (cp = UInt32(c); Char(UInt32(Int32(cp) + lookup(table, cp))))

## The methods of Base that use utf8proc, for characters (`Char`). Those of other `AbstractChar`s
## are not covered: calls with these are rejected, as they would need utf8proc.

@device_override Base.Unicode.category_code(x::Integer) =
    x ≤ 0x10ffff ? Cint(lookup(CATEGORY, UInt32(x))) : Cint(30)

@device_override function Base.Unicode.textwidth(c::Char)
    u = reinterpret(UInt32, c)
    b = bswap(u)
    b < 0x7f && return Int(b >= 0x20) # ASCII, as in Base
    (Base.ismalformed(c) || Base.is_overlong_enc(u)) && return 1
    return Int(lookup(CHARWIDTH, UInt32(c)))
end

@device_override Base.Unicode.lowercase(c::Char) =
    isascii(c) ? ('A' <= c <= 'Z' ? c + 0x20 : c) : mapped(c, TOLOWER)
@device_override Base.Unicode.uppercase(c::Char) =
    isascii(c) ? ('a' <= c <= 'z' ? c - 0x20 : c) : mapped(c, TOUPPER)
@device_override Base.Unicode.titlecase(c::Char) =
    isascii(c) ? ('a' <= c <= 'z' ? c - 0x20 : c) : mapped(c, TOTITLE)

@device_override Base.Unicode.islowercase(c::Char) = Base.ismalformed(c) ? false : lookup(ISLOWER, UInt32(c))
@device_override Base.Unicode.isuppercase(c::Char) = Base.ismalformed(c) ? false : lookup(ISUPPER, UInt32(c))
# (the comparisons of a `Char` are those of its bytes, as in Base: a character that is not valid can be between `'\t'`
# and `'\r'`, and is a space then)
@device_override Base.Unicode.isspace(c::Char) =
    c == ' ' || '\t' <= c <= '\r' || c == '\u85' || '\ua0' <= c && !Base.ismalformed(c) && lookup(ISSPACE, UInt32(c))
@device_override Base.Unicode.isprint(c::Char) = Base.ismalformed(c) ? false : lookup(ISPRINT, UInt32(c))

# The two letters of the category of a character (`Lu`, `Nd`, ...), which `show(io, MIME"text/plain"(), c)` of a `Char`
# writes (`display('a')`), are asked of utf8proc by Base; here they come from the number of the category (see
# `category_code` above), in the order of utf8proc's `UTF8PROC_CATEGORY_*`.
const CATEGORY_ABBREVIATIONS = ("Cn", "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
                                "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co")
@device_override Base.Unicode.category_abbrev(c::AbstractChar) = @inbounds CATEGORY_ABBREVIATIONS[Base.Unicode.category_code(c) + 1]

# Whether a character can start an identifier, and be in one (`Meta.isidentifier`, which `show` of a `NamedTuple` asks of
# the names of its fields): Base asks the parser in libjulia (`jl_id_start_char`, `jl_id_char`). These are functions of
# the code point alone too, and are tabulated from the parser in the same way.
const ID_START = BoolRunTable(cp -> isvalid(Char, cp) && ccall(:jl_id_start_char, Cint, (UInt32,), cp) != 0)
const ID_CHAR = BoolRunTable(cp -> isvalid(Char, cp) && ccall(:jl_id_char, Cint, (UInt32,), cp) != 0)
@device_override Base.Meta.is_id_start_char(c::Char) = isvalid(c) && lookup(ID_START, UInt32(c))
@device_override Base.Meta.is_id_char(c::Char) = isvalid(c) && lookup(ID_CHAR, UInt32(c))
