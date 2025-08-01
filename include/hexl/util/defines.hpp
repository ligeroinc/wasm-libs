// Copyright (C) 2020-2021 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

#pragma once

/* #undef HEXL_USE_MSVC */
/* #undef HEXL_USE_GNU */
#define HEXL_USE_CLANG

/* #undef HEXL_DEBUG */

// Avoid unused variable warnings
#define HEXL_UNUSED(x) (void)(x)
