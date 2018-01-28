#!/bin/sh

wget https://dist.libuv.org/dist/v1.19.0/libuv-v1.19.0.tar.gz

tar xf libuv-v1.19.0.tar.gz

cd libuv-v1.19.0

sh autogen.sh

./configure

make

make install

cd ../

git clone -b devel https://github.com/nim-lang/Nim.git nim

cd nim

git clone --depth 1 https://github.com/nim-lang/csources.git

cd csources

sh build.sh

cd ../

bin/nim c koch

./koch boot -d:release

./koch nimble

./koch tools

rm -rf csources

rm -rf dist/*

cd ../

nim/bin/nim c -d:release app