# compare_golden.cmake — run the wire fixture and diff it against the golden.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# A CMake script rather than a shell script so that it runs identically on the
# Windows CI runner, where there is no `sh` and no `cmp`.

if(NOT EXISTS "${GOLDEN}")
  message(FATAL_ERROR
    "The wire golden is missing: ${GOLDEN}\n"
    "Generate it with:\n"
    "  ${FIXTURE} ${GOLDEN}")
endif()

execute_process(
  COMMAND "${FIXTURE}" "${SCRATCH}"
  RESULT_VARIABLE status
  OUTPUT_QUIET
)
if(NOT status EQUAL 0)
  message(FATAL_ERROR "oaa_wire_fixture failed with status ${status}")
endif()

file(SIZE "${GOLDEN}" golden_size)
file(SIZE "${SCRATCH}" actual_size)

file(MD5 "${GOLDEN}" golden_hash)
file(MD5 "${SCRATCH}" actual_hash)

if(NOT golden_hash STREQUAL actual_hash)
  message(FATAL_ERROR
    "The serialised wire frames no longer match the committed golden.\n"
    "  golden: ${golden_size} bytes, ${golden_hash}\n"
    "  actual: ${actual_size} bytes, ${actual_hash}\n"
    "\n"
    "This is the check described in plugin/test/wire_fixture.cpp. Either the C++\n"
    "serialiser drifted — in which case fix it, do NOT regenerate the golden —\n"
    "or the protocol changed deliberately, in which case bump kProtocolVersion,\n"
    "update docs/WIRE.md and packages/oaa_wire/, and regenerate with:\n"
    "  ${FIXTURE} ${GOLDEN}")
endif()

message(STATUS "wire golden matches: ${actual_size} bytes")
