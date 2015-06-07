with_repo_access("test lookup raises error if object type does not match") do test_repo, path
    # blob
    @test_throws LibGitError{:Invalid,:NotFound} lookup_tree(test_repo, Oid("fa49b077972391ad58037050f2a75f74e3671e92"))
    # commit
    @test_throws LibGitError{:Invalid,:NotFound} lookup_tree(test_repo, Oid("8496071c1b46c854b31185ea97743be6a8774479"))
    # tag
    @test_throws LibGitError{:Invalid,:NotFound} lookup_tree(test_repo, Oid("0c37a5391bbff43c37f0d0371823a5509eed5b1d"))
end

with_repo_access() do test_repo, path 
    id = Oid("c4dc1555e4d4fa0e0c9c3fc46734c7c35b3ce90b")
    test_tree = lookup_tree(test_repo, id)

    context("test read tree data") do 
        @test id == Oid(test_tree)
        @test isa(test_tree, GitTree)
        @test length(test_tree) == 3
        @test Oid(test_tree[1]) == Oid("1385f264afb75a56a5bec74243be9b367ba4ca08")
        @test Oid(test_tree[2]) == Oid("fa49b077972391ad58037050f2a75f74e3671e92")
    end

    context("test read tree entry data") do
        bent = test_tree[1]
        tent = test_tree[3]

        @test name(bent) == "README"
        @test isa(bent, GitTreeEntry{GitBlob})

        @test name(tent) == "subdir"
        @test isa(tent, GitTreeEntry{GitTree})
        @test Oid(tent) == Oid("619f9935957e010c419cb9d15621916ddfcc0b96")
        @test isa(lookup(test_repo, Oid(tent)), GitTree)
    end

    context("test get entry by id") do
        bentid = Oid("1385f264afb75a56a5bec74243be9b367ba4ca08")
        bent = test_tree[bentid]
        @test name(bent) == "README"
        @test isa(bent, GitTreeEntry{GitBlob})
    end

    context("test get entry by id returns nothing if no id") do 
        nadaid = Oid("1385f264afb75a56a5bec74243be9b367ba4ca07")
        nada = test_tree[nadaid]
        @test nada == nothing
    end

    context("test get entry by path") do
        bent = entry_bypath(test_tree, "README")
        @test Oid(bent) == Oid("1385f264afb75a56a5bec74243be9b367ba4ca08")
        @test isa(bent, GitTreeEntry{GitBlob})
    end

    context("test get entry by path returns nothing if not found") do
        nada = entry_bypath(test_tree, "NADA")
        @test nada == nothing
    end

    context("test tree iteration") do
        @test length(collect(test_tree)) == length(test_tree)
        tes = sort(collect(test_tree))
        str = join([name(te) for te in tes], ":")
        @test str == "README:subdir:new.txt"
    end
    
    context("test tree walk only trees") do
        walk(GitTree, test_tree, :postorder) do res
            root, entry = res
            @assert isa(entry, GitTreeEntry{GitTree})
        end
    end

    context("test tree walk only blob") do 
        walk(GitBlob, test_tree, :postorder) do res
            root, entry = res
            @test isa(entry, GitTreeEntry{GitBlob})
        end
    end
    
    context("test iterate subtrees") do
        for t in foreach(GitTree, test_tree)
            @test isa(t, GitTreeEntry{GitTree})
        end
    end

    context("test iterate subtree blobs") do
        for b in foreach(GitBlob, test_tree)
            @test isa(b, GitTreeEntry{GitBlob})
        end
    end
end

#TODO: more tree builder tests
with_tmp_repo_access("test tree builder") do test_repo, path
  builder = GitTreeBuilder(test_repo)
  insert!(builder, "README.txt", 
                   Oid("1385f264afb75a56a5bec74243be9b367ba4ca08"),
                   33188)
  id = write!(builder)
  obj = test_repo[id]
  @test isa(obj, GitTree)
  @test length(raw(obj)) == 38
end
