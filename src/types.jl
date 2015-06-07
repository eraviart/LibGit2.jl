export Signature, GitRepo, GitObject, GitAnyObject, GitBlob, GitCommit, GitTag,
       GitTree, GitReference, GitBranch, GitRemote, Sym

typealias GitOffT Int64
typealias GitTimeT Int64

typealias MaybeDict Union(Nothing, Dict{Any,Any})
typealias MaybeString Union(Nothing, String)

# time in a signature

immutable TimeStruct
    time::GitTimeT # time in seconds from epoch
    offset::Cint   # timezone offset in minutes
end
TimeStruct() = TimeStruct(zero(GitTimeT), zero(Cint))

# an action signature (committers, taggers, etc)
immutable SignatureStruct
    name::Ptr{Uint8}  # full name of the author
    email::Ptr{Uint8} # email of the author
    when::TimeStruct  # time when the action happened
end
SignatureStruct() = SignatureStruct(zero(Ptr{Uint8}),
                                    zero(Ptr{Uint8}),
                                    TimeStruct())
immutable BufferStruct
    ptr::Ptr{Uint8}
    asize::Csize_t
    size::Csize_t
end
BufferStruct() = BufferStruct(C_NULL, 0, 0)

Base.bytestring(b::BufferStruct) = bytestring(b.ptr, b.size)

immutable TransferProgressStruct
    total_objects::Cuint
    indexed_objects::Cuint
    received_objects::Cuint
    local_objects::Cuint
    total_deltas::Cuint
    indexed_deltas::Cuint
    received_bytes::Csize_t
end
TransferProgressStruct() = TransferProgressStruct(zero(Cuint),
                                                  zero(Cuint),
                                                  zero(Cuint),
                                                  zero(Cuint),
                                                  zero(Cuint),
                                                  zero(Cuint),
                                                  zero(Csize_t))

# pointers to string data must not be valid references
# for the entire lifetime of the ccall
immutable StrArrayStruct
   strings::Ptr{Ptr{Uint8}}
   count::Csize_t
end
StrArrayStruct() = StrArrayStruct(zero(Ptr{Uint8}), zero(Csize_t))

StrArrayStruct{T<:String}(strs::Vector{T}) = begin
    count = length(strs)
    strings = convert(Ptr{Ptr{Uint8}}, Base.c_malloc(sizeof(Ptr{Uint8}) * count))
    for i=1:count
        len = length(strs[i])
        in_ptr  = convert(Ptr{Uint8}, bytestring(strs[i]))
        out_ptr = convert(Ptr{Uint8}, Base.c_malloc(sizeof(Uint8) * (len + 1)))
        unsafe_copy!(out_ptr, in_ptr, len)
        unsafe_store!(out_ptr, zero(Uint8), len + 1) # NULL byte
        unsafe_store!(strings, out_ptr, i)
    end
    return StrArrayStruct(strings, count)
end
StrArrayStruct{T<:String}(str::T) = StrArrayStruct([str])

Base.convert(::Type{Vector{UTF8String}}, sa::StrArrayStruct) = begin
    arr = Array(UTF8String, sa.count)
    for i=1:sa.count
        arr[i] = utf8(bytestring(unsafe_load(sa.strings, i)))
    end
    return arr
end

free!(sa::StrArrayStruct) = begin
    sa_ptr = [sa]
    ccall((:git_strarray_free, libgit2), Void, (Ptr{StrArrayStruct},), sa_ptr)
    return sa_ptr[1]
end

# git config entry struct
immutable ConfigEntryStruct
    name::Ptr{Uint8}
    value::Ptr{Uint8}
    level::Cint
end

typealias DiffDeltaT Cint

@eval begin
    $(Expr(:type, false, :HeaderStruct,
        Expr(:block, 
            [Expr(:(::), symbol("c$i"), :Uint8) for i=1:128]...)))
end

immutable DiffHunkStruct
    old_start::Cint
    old_lines::Cint
    new_start::Cint
    new_lines::Cint
    header_len::Csize_t
    header::HeaderStruct
end

immutable DiffFileStruct
    id::Oid
    path::Ptr{Uint8}
    size::Coff_t
    flags::Uint32
    mode::Uint16
end

immutable DiffDeltaStruct 
    status::DiffDeltaT
    flags::Uint32
    similarity::Uint16
    nfiles::Uint16
    old_file::DiffFileStruct
    new_file::DiffFileStruct
end

immutable DiffLineStruct
    origin::Cchar
    old_lineno::Cint
    new_lineno::Cint
    num_lines::Cint
    content_len::Csize_t
    content_offset::Coff_t
    # pointer to diff text, ! this is not NULL byte terminated
    content::Ptr{Uint8}
end

# git diff option struct
immutable DiffOptionsStruct
    version::Cuint
    flags::Uint32 

    # options controlling which files are in the diff
    ignore_submodules::Cint
    pathspec::StrArrayStruct
    notify_cb::Ptr{Void}
    notify_payload::Ptr{Void}

    # options controlling how the diff text is generated
    context_lines::Uint16
    interhunk_lines::Uint16
    id_abbrev::Uint16
    max_size::Coff_t
    old_prefix::Ptr{Uint8}
    new_prefix::Ptr{Uint8}
end 
DiffOptionsStruct() = DiffOptionsStruct(GitConst.DIFF_OPTIONS_VERSION,
                                        zero(Uint32),
                                        GitConst.SUBMODULE_IGNORE_DEFAULT, 
                                        StrArrayStruct(),
                                        zero(Ptr{Void}),
                                        zero(Ptr{Void}),
                                        convert(Uint16, 3),
                                        zero(Uint16),
                                        zero(Uint16),
                                        zero(Coff_t),
                                        zero(Ptr{Uint8}),
                                        zero(Ptr{Uint8}))
immutable RemoteHeadStruct
    islocal::Cint
    id::Oid
    lid::Oid
    name::Ptr{Uint8}
end

immutable MergeTreeOptsStruct
    version::Cuint
    flags::Cint
    rename_threshold::Cuint
    target_limit::Cuint
    metric::Ptr{Void}
    automerge_flags::Cint
end

MergeTreeOptsStruct() = MergeTreeOptsStruct(one(Cuint),
                                            zero(Cint),
                                            zero(Cuint),
                                            zero(Cuint),
                                            zero(Ptr{Void}),
                                            zero(Cint))
                                            
immutable DiffFileStruct
    id::Oid
    path::Ptr{Uint8}
    size::Coff_t
    flags::Uint32
    mode::Uint16
end

immutable CheckoutOptionsStruct
    version::Cuint
    checkout_strategy::Cuint
    disable_filters::Cint
    dir_mode::Cuint
    file_mode::Cuint
    file_open_flags::Cint
    notify_flags::Cuint
    notify_cb::Ptr{Void}
    notify_payload::Ptr{Void}
    progress_cb::Ptr{Void}
    progress_payload::Ptr{Void}
    paths::StrArrayStruct
    baseline::Ptr{Void}
    target_directory::Ptr{Uint8}
    ancestor_label::Ptr{Uint8}
    our_label::Ptr{Uint8}
    their_label::Ptr{Uint8}
end
CheckoutOptionsStruct() = CheckoutOptionsStruct(one(Cuint), 
                                                GitConst.CHECKOUT_SAFE_CREATE,
                                                zero(Cint),
                                                zero(Cuint),
                                                zero(Cuint),
                                                zero(Cint),
                                                zero(Cuint),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}),
                                                StrArrayStruct(),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Uint8}),
                                                zero(Ptr{Uint8}),
                                                zero(Ptr{Uint8}),
                                                zero(Ptr{Uint8}))
immutable RemoteCallbacksStruct 
    version::Cuint
    sideband_progress::Ptr{Void}
    completion::Ptr{Void}
    credentials::Ptr{Void}
    transfer_progress::Ptr{Void}
    update_tips::Ptr{Void}
    payload::Ptr{Void}
end
RemoteCallbacksStruct() = RemoteCallbacksStruct(one(Cuint),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}), 
                                                zero(Ptr{Void}),
                                                zero(Ptr{Void}))
immutable CloneOptionsStruct
    version::Cuint
    checkout_opts::CheckoutOptionsStruct
    remote_callbacks::RemoteCallbacksStruct
    bare::Cint
    ignore_cert_errors::Cint
    localclone::Cint # GitCloneLocalT
    remote_name::Ptr{Uint8}
    checkout_branch::Ptr{Uint8}
    signature::Ptr{SignatureStruct}
end

CloneOptionsStruct() = CloneOptionsStruct(one(Cuint),
                                          CheckoutOptionsStruct(),
                                          RemoteCallbacksStruct(),
                                          zero(Cint),
                                          zero(Cint),
                                          zero(Cint),
                                          zero(Ptr{Uint8}),
                                          zero(Ptr{Uint8}),
                                          zero(Ptr{SignatureStruct}))
# --------------
# Git Signature
# --------------

type Signature
    name::UTF8String
    email::UTF8String
    time::Int64
    time_offset::Int32
end

# --------------
# Git Repository
# --------------
type GitRepo
    ptr::Ptr{Void}
    
    function GitRepo(ptr::Ptr{Void}, own::Bool=true)
        @assert ptr != C_NULL
        r = new(ptr)
        own && finalizer(r, free!)
        return r
    end
end

free!(r::GitRepo) = begin
    if r.ptr != C_NULL
        try 
            close(r)
        finally
            ccall((:git_repository_free, libgit2), Void, (Ptr{Void},), r.ptr)
            r.ptr = C_NULL
        end
    end
end

Base.convert(::Type{Ptr{Void}}, r::GitRepo) = r.ptr

# -------------
# Git Objects
# -------------
abstract GitObject

free!(o::GitObject) = begin
    if o.ptr != C_NULL
        ccall((:git_object_free, libgit2), Void, (Ptr{Void},), o.ptr)
        o.ptr = C_NULL
    end
end

type GitAnyObject <: GitObject end

GitAnyObject(ptr::Ptr{Void}) = begin
    @assert ptr != C_NULL
    typ = ccall((:git_object_type, libgit2), Cint, (Ptr{Void},), ptr)
    T = gitobj_const_type(typ)
    return T(ptr)
end

type GitBlob <: GitObject
    ptr::Ptr{Void}
    
    function GitBlob(ptr::Ptr{Void})
        @assert ptr != C_NULL
        this = new(ptr)
        finalizer(this, free!)
        return this 
    end
end

Base.convert(::Type{Ptr{Void}}, b::GitBlob) = b.ptr

type GitCommit <: GitObject
    ptr::Ptr{Void}

    function GitCommit(ptr::Ptr{Void})
        @assert ptr != C_NULL
        this = new(ptr)
        finalizer(this, free!)
        return this
    end
end

Base.convert(::Type{Ptr{Void}}, c::GitCommit) = c.ptr

type GitTag <: GitObject
    ptr::Ptr{Void}

    function GitTag(ptr::Ptr{Void})
        @assert ptr != C_NULL 
        this = new(ptr)
        finalizer(this, free!)
        return this
    end
end

Base.convert(::Type{Ptr{Void}}, o::GitTag) = o.ptr 

type GitTree <: GitObject
    ptr::Ptr{Void}

    function GitTree(ptr::Ptr{Void})
        @assert ptr != C_NULL
        this = new(ptr)
        finalizer(this, free!)
        return this
    end
end

Base.convert(::Type{Ptr{Void}}, o::GitTree) = o.ptr

git_otype(::Type{GitBlob})      = GitConst.OBJ_BLOB
git_otype(::Type{GitCommit})    = GitConst.OBJ_COMMIT
git_otype(::Type{GitTag})       = GitConst.OBJ_TAG 
git_otype(::Type{GitTree})      = GitConst.OBJ_TREE
git_otype(::Type{GitAnyObject}) = GitConst.OBJ_ANY

git_otype{T<:GitObject}(o::T) = git_otype(T)

# ---------------
# Git Reftypes
# ---------------
immutable Sym end 
const RefType = Union(Oid, Sym)

type GitReference{T<:RefType}
    ptr::Ptr{Void}
end

free!(r::GitReference) = begin
    if r.ptr != C_NULL
        ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), r.ptr)
        r.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, r::GitReference) = r.ptr

# TODO: git branch should be a subtype of GitReference
type GitBranch
    ptr::Ptr{Void}
    
    function GitBranch(ptr::Ptr{Void})
        @assert ptr != C_NULL
        this = new(ptr)
        finalizer(this, free!)
        return this
    end
end

Base.convert(::Type{Ptr{Void}}, o::GitBranch) = o.ptr

free!(b::GitBranch) = begin
    if b.ptr != C_NULL
        ccall((:git_reference_free, libgit2), Void, (Ptr{Void},), b.ptr)
        b.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, b::GitBranch) = b.ptr

# ---------------
# Git Remote
# ---------------
type GitRemote
    ptr::Ptr{Void}

    function GitRemote(ptr::Ptr{Void})
        @assert ptr != C_NULL
        r = new(ptr)
        finalizer(r, free!)
        return r
    end
end

free!(r::GitRemote) = begin
    if r.ptr != C_NULL
        ccall((:git_remote_free, libgit2), Void, (Ptr{Void},), r.ptr)
        r.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, r::GitRemote) = r.ptr
