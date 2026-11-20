# Base64 and CRC32c, compared with Julia (Base64 is the standard library's own: its streams are compiled as they are, with the tasks and locks of `tasks.jl` that they are not run with).

# (`base64encode(::Any)` is made over the registered types: a `Vector{Int}` that comes out of `any_value` is one of them when it is added)
StaticRuntime.add_dispatch_candidates!(Vector{Int})

@testset "Base64" begin
    check_cases([
        "Base64 encode"            => () -> (println(base64encode(any_value("hello world")), base64encode(UInt8[]), base64encode("a"), base64encode("ab")); 0),
        "Base64 decode"            => () -> (println(String(base64decode(any_value("aGVsbG8gd29ybGQ=")))); println(String(base64decode(any_value("aGVsbG8")))); 0),
        "Base64 round trip"        => () -> (b = Vector{UInt8}(1:200); Int(base64decode(base64encode(b)) == b)),
        "Base64 of a SubString"    => () -> (s = any_value("hello world"); println(base64encode(SubString(s, 1, 5))); println(String(base64decode(SubString(any_value("xxaGVsbG8=yy"), 3, 10)))); 0),
        "Base64 of numbers"        => () -> (println(base64encode(any_value(123456))); println(base64encode(any_value(1.5))); println(base64encode(any_value([1, 2, 3]))); 0),
        "Base64 of what a function writes" => () -> (println(base64encode(io -> print(io, "hello"))); 0),
        "Base64 pipes"             => () -> (b = IOBuffer(); p = Base64EncodePipe(b); write(p, "hello world"); close(p); s = String(take!(b)); println(s); d = Base64DecodePipe(IOBuffer(s)); println(String(read(d))); 0),
        "Base64 decode, white space and an error" => () -> (println(String(base64decode(any_value("aGVs\nbG8=")))); try; base64decode(any_value("a")); 0; catch e; e isa ArgumentError ? 1 : 2; end),
    ])
end

@testset "CRC32c" begin
    check_cases([
        "CRC32c"                   => () -> Int(crc32c(any_value("hello"))) + Int(crc32c(UInt8[1, 2, 3, 4, 5], 0x12345678)),
        "CRC32c of integers and a UUID (Base's `_crc32c`)" => () -> Int(Base._crc32c(any_value(0x0123456789abcdef))) + Int(Base._crc32c(any_value(0x2a), 0x12345678)) +
                                                                    Int(Base._crc32c(Base.UUID(any_value(0x4ba3cbd03c8b4d8e9b8c2f2f2b0e6a71)::UInt128))),
    ])
end

