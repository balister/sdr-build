Building Software Defined Radio (SDR) systems based on meta-sdr
=============================================
This repository provides git submodules to setup the OpenEmbedded build system
with meta-sdr and possibly one or more BSP's (based on the branch you select).

OpenEmbedded allows the creation of custom linux distributions for embedded
systems. It is a collection of git repositories known as *layers* each of
which provides *recipes* to build software packages as well as configuration
information.

Information about the branch names is available at
https://wiki.yoctoproject.org/wiki/Releases. Helpful articles about working
with GNUradio and Openembedded are at: http://www.opensdr.com/categories/.

Getting Started
---------------

1. Clone the git repository:

    $ git clone https://github.com/balister/sdr-build.git

2. Check out the appropriate branch:

    $ cd sdr-build
    $ git checkout -b zeus-xilinx origin/zeus-xilinx

3. Update the submodules:

    $ git submodule update --init

4. Initialize the build system:

    $ TEMPLATECONF=\`pwd\`/meta-sdr/conf-xilinx/ source ./openembedded-core/oe-init-build-env ./build ./bitbake

5. Select the MACHINE to build for:

    $ export MACHINE=zc702-zynq7   (default from local.conf)

6. Build an image:

    $ bitbake gnuradio-dev-image (or maybe core-image-minimal for a quick test)

7. Build another image:

    $ bitbake gnuradio-demo-image

8. Build and sdk:

    $ bitbake -c populate_sdk gnuradio-dev-image

