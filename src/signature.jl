export  name, email, time, time_offset

typealias MaybeSignature Union(Nothing, Signature)

#TODO: better date / time integration when this becomes available in Base
Signature(name::String, email::String) = begin
    sig_ptr = Ptr{SignatureStruct}[0]
    @check ccall((:git_signature_now, libgit2), Cint,
                 (Ptr{Ptr{SignatureStruct}}, Ptr{Uint8}, Ptr{Uint8}), sig_ptr, name, email)
    s = Signature(sig_ptr[1])
    ccall((:git_signature_free, libgit2), Void, (Ptr{SignatureStruct},), sig_ptr[1])
    return s
end

Signature(ptr::Ptr{SignatureStruct}) = begin
    sig   = unsafe_load(ptr)::SignatureStruct
    name  = utf8(bytestring(sig.name))
    email = utf8(bytestring(sig.email))
    time   = sig.when.time
    offset = sig.when.offset
    return Signature(name, email, time, offset)
end

Base.show(io::IO, s::Signature) = begin
    time_str = strftime("%Y-%m-%d %H:%M:%S %Z", s.time)
    print(io, "Signature(\"$(name(s))\",\"$(email(s))\",\"$time_str\")")
end

Base.(:(==))(sig1::Signature, sig2::Signature) = (sig1.name == sig2.name &&
                                                  sig1.email == sig2.email &&
                                                  sig1.time == sig2.time &&
                                                  sig1.time_offset == sig2.time_offset)

Base.isequal(sig1::Signature, sig2::Signature) = (sig1 == sig2)

Base.convert(::Type{Ptr{SignatureStruct}}, sig::Signature) = begin
    sig_ptr = Ptr{SignatureStruct}[0]
    @check ccall((:git_signature_new, libgit2), Cint,
                 (Ptr{Ptr{SignatureStruct}}, Ptr{Uint8}, Ptr{Uint8}, GitTimeT, Cint),
                 sig_ptr, sig.name, sig.email, sig.time, sig.time_offset)
    return sig_ptr[1]::Ptr{SignatureStruct}
end

name(s::Signature)  = s.name
email(s::Signature) = s.email

#TODO: remove
Base.time(s::Signature) = s.time
time_offset(s::Signature) = s.time_offset
