# Input: transcript lines carrying "usage". Assistant messages repeat once per content
# block with the same message id and usage, so each id counts once. Unknown models add 0.
include "pricing";
map(select(.type == "assistant" and .message.usage and .message.id)) | unique_by(.message.id)
| map(price(.message.model) as $r | .message.usage as $u
    | if $r == null then 0 else
        ($u.input_tokens // 0) * $r.input + ($u.output_tokens // 0) * $r.output
        + ($u.cache_read_input_tokens // 0) * $r.cache_read
        + ($u.cache_creation_input_tokens // 0) * $r.cache_write
      end)
| add // 0
