#!/bin/bash

swift build -c release -Xswiftc -static-stdlib
cp .build/release/selfish .
tar -czvf selfish.tgz selfish
rm selfish
