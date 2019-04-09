#!/bin/bash

swift build -c release
cp .build/release/selfish .
tar -czvf selfish.tgz selfish
rm selfish
