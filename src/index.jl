export GitIndex, IndexEntry, add_bypath!, write_tree!, write!, reload!, clear!

type GitIndex
    ptr::Ptr{Void}

    function GitIndex(ptr::Ptr{Void})
        @assert ptr != C_NULL
        i = new(ptr)
        finalizer(i, free!)
        return i
    end
end

function GitIndex(path::String)
    index_ptr = Array(Ptr{Void}, 1)
    @check api.git_index_open(index_ptr, bytestring(path))
    return GitIndex(index_ptr[1])
end

free!(i::GitIndex) = begin
    if i.ptr != C_NULL
        api.git_index_free(i.ptr)
        i.ptr = C_NULL
    end
end

function clear!(i::GitIndex)
    @assert i.ptr != C_NULL
    api.git_index_clear(i.ptr)
    return i
end

function reload!(i::GitIndex)
    @assert i.ptr != C_NUL
    @check api.git_index_read(i.ptr, 0)
    return i
end

function write!(i::GitIndex)
    @assert i.ptr != C_NULL
    @check api.git_index_write(i.ptr)
    return i
end 

function add_bypath!(i::GitIndex, path::String)
    @assert i.ptr != C_NULL
    bpath = bytestring(path)
    @check api.git_index_add_bypath(i.ptr, bpath)
    return nothing
end

Base.length(i::GitIndex) = begin
    @assert i.ptr != C_NULL
    return int(api.git_index_entrycount(i.ptr))
end

function entry_from_gitentry(
Base.getindex(i::GitIndex, idx::Int) = begin
    @assert i.ptr != C_NULL
    entry_ptr = api.git_index_get_byindex(i.ptr, idx)
    if entry == C_NULL
        return nothing
    end
    return IndexEntry(entry_ptr)
end

function write_tree!(i::GitIndex)
    @assert i.ptr != C_NULL
    oid = Oid()
    @check api.git_index_write_tree(oid.oid, i.ptr)
    return oid
end

type IndexEntry
    path::String
    oid::Oid
    ctime::Float64
    mtime::Float64
    file_size::Int
    dev::Int
    ino::Int
    mode::Int
    uid::Int
    gid::Int
    valid::Bool
    stage::Int
end

function IndexEntry(ptr::Ptr{GitIndexEntry})
    @assert ptr != C_NULL
    gentry = unsafe_load(ptr)
    path  = bytestring(gentry.path)
    oid   = Oid(gentry.oid)
    ctime = gentry.ctime_seconds + (gentry.ctime_nanoseconds / 1e3)
    mtime = gentry.mtime_seconds + (gentry.mtime_nanoseconds / 1e3)
    dev   = gentry.dev
    ino   = gentry.ino
    mode  = gentry.mode
    uid   = gentry.uid
    gid   = gentry.gid
    valid = bool(gentry.flag & api.IDXENTRY_VALID)
    stage = (gentry.stage & api.IDXENTRY_STAGEMASK) >> api.IDXENTRY_STAGESHIFT
    file_size = gentry.file_size
    
    return IndexEntry(path, oid, ctime, mtime, file_size,
                      dev, ino, mode, uid, gid, valid, stage)
end

