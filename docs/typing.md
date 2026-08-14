# idiomatic balanced low friction type safety

## distinct
Odin has the `distinct` keyword for types with a common lower level representation but different purposes.

Analyze the project for where distinct could help reduce errors balanced against the possible friction of using it.
Note that friction may also be good in a documentative clarity aspect.

There's a lot of e.g. `Uint` for different purposes

## default params
odin allows default parameters. C does not have these, but maybe somethings are very commonly a nil value in which case a default makes sense.

## review FFI types

we should have enums and bitsets where idiomatic and relevant at this point. fixed sets of numeric values become enums

e.g. is `eventCode` a constrained set of numbers in the C headers? appEventCode?

## odin wrappers

almost separate to the typing, if there's some frequent ugly api usage with high friction then a wrapper may make
sense, but needs discussion and may already exist as part of adding interfaces to the raw isciterapi

