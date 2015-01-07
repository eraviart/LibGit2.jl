using BinDeps

@BinDeps.setup

version = v"0.22.0-rc1"
libgit2 = library_dependency("libgit2",
    validate = (name, handle) -> begin
        major, minor, patch = Cint[0], Cint[0], Cint[0]
        ccall(dlsym(handle, :git_libgit2_version), Void,
              (Ptr{Cint}, Ptr{Cint}, Ptr{Cint}), major, minor, patch)
        v = VersionNumber(major[1], minor[1])
        if v.major == version.major && v.minor == version.minor
            return true
        else
            return false
        end
    end
)

provides(Sources,
         URI("https://github.com/libgit2/libgit2/archive/v$version.tar.gz"),
         libgit2,
         unpacked_dir="libgit2-$version")

# Windows binaries built in MSYS2 via:
# /d/code/CMake-2.8/bin/cmake .. -DCMAKE_INSTALL_PREFIX=$PWD/usr -G"MSYS Makefiles"
# /d/code/CMake-2.8/bin/cmake --build . --target install
provides(Binaries, URI("http://sourceforge.net/projects/juliadeps-win/files/libgit2-v$version.7z"),
         libgit2, unpacked_dir="usr$WORD_SIZE/bin", os = :Windows)

prefix = joinpath(BinDeps.depsdir(libgit2),"usr")
srcdir = joinpath(BinDeps.depsdir(libgit2),"src","libgit2-$version")

provides(SimpleBuild,
    (@build_steps begin
        GetSources(libgit2)
        @build_steps begin
            ChangeDirectory(srcdir)
            `cmake . -DCMAKE_INSTALL_PREFIX=$prefix
                     -DCMAKE_BUILD_TYPE=Release
                     -DTHREADSAFE=ON
                     -DBUILD_CLAR=OFF`
            `make install`
        end
    end), libgit2, os = :Unix)

@BinDeps.install [:libgit2 => :libgit2]

cd(Pkg.dir("LibGit2")) do
    run(`git submodule init`)
    run(`git submodule update`)
end
