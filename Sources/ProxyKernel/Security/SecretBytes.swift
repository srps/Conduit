// SPDX-License-Identifier: Apache-2.0
// `SecretBytes` is implemented in `ConduitShared` (decision 0018). This alias
// keeps existing `ProxyKernel` call sites unchanged during the migration; it
// names the same type rather than a copy of it.

import ConduitShared

package typealias SecretBytes = ConduitShared.SecretBytes
