# Selfish

Run `swift build -c release`, then run `selfish` from the directory whose Swift
files you want to add explicit `self` references to.

Selfish will automatically insert explicit `self` references in the Swift files
it finds.

Note: you need to have built the Swift file(s) with Xcode recently since Selfish
finds the compiler arguments needed to analyze the files in your Derived Data
directory.
