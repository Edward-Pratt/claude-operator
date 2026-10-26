# Price row for a model id from pricing.json ($p): the exact id (snapshot date dropped),
# else the newest model of the same family, else null.
def price($m):
  ($m // "" | sub("-[0-9]{8}$"; "")) as $id
  | ($p.models // {}) as $models
  | $models[$id] // $models[($p.families // {})[($id | split("-")[1] // "")] // ""] // null;
