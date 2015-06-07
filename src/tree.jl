export GitTreeEntry, 
       entry_byname, entry_bypath, walk

type GitTreeEntry{T<:GitObject}
    name::ByteString
    id::Oid
    filemode::Cint
    owns::Bool
end

Oid(te::GitTreeEntry)  = te.id
name(te::GitTreeEntry) = te.name

Base.isless(te1::GitTreeEntry, te2::GitTreeEntry) = isless(Oid(te1), Oid(te2))

Base.length(t::GitTree) = 
    int(ccall((:git_tree_entrycount, libgit2), Csize_t, (Ptr{Void},), t))
                               
Base.filemode(te::GitTreeEntry) = te.filemode

let 
    function tree_entry_name(ptr::Ptr{Void})
        nptr = ccall((:git_tree_entry_name, libgit2), Ptr{Uint8}, (Ptr{Void},), ptr)
        return bytestring(nptr)
    end

    function tree_entry_oid(ptr::Ptr{Void})
        idptr = ccall((:git_tree_entry_id, libgit2), Ptr{Uint8}, (Ptr{Void},), ptr)
        return Oid(idptr)
    end

    function tree_entry_type(ptr::Ptr{Void})
        t = ccall((:git_tree_entry_type, libgit2), Cint, (Ptr{Void},), ptr)
        t == GitConst.OBJ_BLOB   && return GitBlob
        t == GitConst.OBJ_COMMIT && return GitCommit
        t == GitConst.OBJ_TAG    && return GitTag
        t == GitConst.OBJ_TREE   && return GitTree
        throw(ArgumentError("Unknown tree_entry_type constant $(t)"))
    end

    function tree_entry_filemode(ptr::Ptr{Void})
        ccall((:git_tree_entry_filemode, libgit2), Cint, (Ptr{Void},), ptr)
    end

    function GitTreeEntry(ptr::Ptr{Void}, owns::Bool=false)
        @assert ptr != C_NULL
        ty   = tree_entry_type(ptr)
        name = tree_entry_name(ptr)
        id   = tree_entry_oid(ptr)
        fm   = tree_entry_filemode(ptr)
        owns && ccall((:git_tree_entry_free, libgit2), Void, (Ptr{Void},), ptr)
        return GitTreeEntry{ty}(name, id, fm, owns)
    end
end

function entry_byname(t::GitTree, filename::String)
    eptr = ccall((:git_tree_entry_byname, libgit2), Ptr{Void},
                 (Ptr{Void}, Ptr{Uint8}), t, filename)
    return eptr == C_NULL ? nothing : 
                            GitTreeEntry(eptr, false)
end

function entry_bypath(t::GitTree, path::String)
    entry_ptr = Ptr{Void}[0]
    ccall((:git_tree_entry_bypath, libgit2), Cint,
                  (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}), entry_ptr, t.ptr, path)
    return entry_ptr[1] == C_NULL ? nothing :
                                    GitTreeEntry(entry_ptr[1], true)
end

function entry_byindex(t::GitTree, idx::Integer)
    entry_ptr = ccall((:git_tree_entry_byindex, libgit2), Ptr{Void},
                      (Ptr{Void}, Csize_t), t, idx - 1) 
    return entry_ptr == C_NULL ? nothing :
                                 GitTreeEntry(entry_ptr, false)
end

function entry_byid(t::GitTree, id::Oid)
    entry_ptr = ccall((:git_tree_entry_byid, libgit2), Ptr{Void},
                      (Ptr{Void}, Ptr{Oid}), t, &id)
    return entry_ptr == C_NULL ? nothing :
                                 GitTreeEntry(entry_ptr, false)
end

Base.getindex(t::GitTree, entry::Integer) = entry_byindex(t, entry)
Base.getindex(t::GitTree, entry::String)  = entry_byname(t, entry)
Base.getindex(t::GitTree, entry::Oid)     = entry_byid(t, entry)

Base.start(t::GitTree) = begin
    te = entry_byindex(t, 1)
    return (1, te)
end

Base.done(t::GitTree, state) = state[1] > length(t)

Base.next(t::GitTree, state) = begin
    nidx = state[1] + 1
    (state[2], (nidx, entry_byindex(t, nidx)))
end

function foreach(::Type{GitBlob}, t::GitTree)
    @task for te in t
        isa(te, GitTreeEntry{GitBlob}) && produce(te)
    end
end

function foreach(::Type{GitTree}, t::GitTree)
    @task for te in t
        isa(te, GitTreeEntry{GitTree}) && produce(te)
    end
end

function cb_treewalk(root::Ptr{Uint8}, entry::Ptr{Void}, data::Ptr{Void})
    try 
        produce(bytestring(root), GitTreeEntry(entry))
        return GitErrorConst.GIT_OK
    catch err
        return GitErrorConst.ERROR
    end
end

const c_cb_treewalk = cfunction(cb_treewalk, Cint, 
                                (Ptr{Uint8}, Ptr{Void}, Ptr{Void}))
 
function walk(t::GitTree, order=:postorder)
    mode = order == :postorder ? GitConst.TREEWALK_POST :
           order == :preorder  ? GitConst.TREEWALK_PRE  :
           throw(ArgumentError("walk order can be :preorder or :postorder, got :$order"))
    @task ccall((:git_tree_walk, libgit2), Cint,
                (Ptr{Void}, Cint, Ptr{Void}, Ptr{Void}), 
                t, mode, c_cb_treewalk, C_NULL)
end

function walk(::Type{GitBlob}, t::GitTree, order::Symbol=:postorder)
    @task for res in walk(t, order)
        isa(res[2], GitTreeEntry{GitBlob}) && produce(res)
    end
end

function walk(f::Function, ::Type{GitBlob}, t::GitTree, order::Symbol=:postorder)
    for res in walk(GitBlob, t, order) 
        f(res)
    end
end

function walk(::Type{GitTree}, t::GitTree, order::Symbol=:postorder)
    @task for res in walk(t, order)
        isa(res[2], GitTreeEntry{GitTree}) && produce(res)
    end
end

function walk(f::Function, ::Type{GitTree}, t::GitTree, order::Symbol=:postorder)
    for res in walk(GitTree, t, order)
        f(res)
    end
end

#------- Tree Builder -------
type GitTreeBuilder
    ptr::Ptr{Void}
    repo::GitRepo
    
    function GitTreeBuilder(ptr::Ptr{Void}, r::GitRepo)
        @assert ptr != C_NULL
        tb = new(ptr, r)
        finalizer(tb, free!)
        return tb
    end
end

GitTreeBuilder(r::GitRepo) = begin
    tbptr = Ptr{Void}[0] 
    @check ccall((:git_treebuilder_create, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}), tbptr, C_NULL)
    return GitTreeBuilder(tbptr[1], r)
end 

free!(tb::GitTreeBuilder) = begin
    if tb.ptr != C_NULL
        ccall((:git_treebuilder_free, libgit2), Void, (Ptr{Void},), tb.ptr)
        tb.ptr = C_NULL
    end
end

Base.convert(::Type{Ptr{Void}}, tb::GitTreeBuilder) = tb.ptr

# the number of entries in a tree builder
Base.length(tb::GitTreeBuilder) = begin
    return int(ccall((:git_treebuilder_entrycount, libgit2), Cuint, (Ptr{Void},), tb))
end 

# add / update an entry to the builder
Base.insert!(tb::GitTreeBuilder, filename::String, id::Oid, filemode::Int) = begin
    if !(id in tb.repo)
        throw(ArgumentError("OID $id does not exist in the Object Database"))
    end
    @check ccall((:git_treebuilder_insert, libgit2), Cint,
                 (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Uint8}, Ptr{Oid}, Cint),
                 C_NULL, tb, filename, &id, filemode)
    return tb
end

# get an entry from the builder from its filename
Base.getindex(tb::GitTreeBuilder, filename::String) = begin
    entry_ptr = ccall((:git_treebuilder_get, libgit2), Ptr{Void}, 
                      (Ptr{Void}, Ptr{Uint8}), tb, filename)
    return GitTreeEntry(ptr)
end

function cb_tbfilter(te_ptr::Ptr{Void}, payload::Ptr{Void})
    te = GitTreeEntry(te_ptr)
    func = unsafe_pointer_to_objref(payload)::Vector{Any}
    return bool(func(te)) ? one(Cint) : zero(Cint)
end

const c_cb_tbfilter = cfunction(cb_tbfilter, Cint, (Ptr{Void}, Ptr{Void}))

# selectively remote entries in the tree
Base.filter!(f::Function, tb::GitTreeBuilder) = begin
    f_ptr = pointer_from_objref(f)
    ccall((:git_treebuilder_filter, libgit2), Void, 
          (Ptr{Void}, Ptr{Void}, Ptr{Void}), tb, c_cb_tbfilter, f_ptr)
    return tb
end

# clear all entries in the builder
clear!(tb::GitTreeBuilder) = 
    ccall((:git_treebuilder_clear, libgit2), Void, (Ptr{Void},), tb)

# write the contents of the tree builder as a tree object
function write!(tb::GitTreeBuilder)
    id_ptr = [Oid()]
    @check ccall((:git_treebuilder_write, libgit2), Cint,
                 (Ptr{Oid}, Ptr{Void}, Ptr{Void}), id_ptr, tb.repo, tb) 
    return id_ptr[1]
end
