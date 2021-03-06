<?hh

function block() {
  return RescheduleWaitHandle::create(
    RescheduleWaitHandle::QUEUE_NO_PENDING_IO,
    1,
  );
}
async function num() {
  var_dump(func_num_args());
  await block();
  var_dump(func_num_args());
}

async function arg() {
  for ($i = 0; $i < func_num_args(); ++$i) {
    var_dump(func_get_arg($i));
  }
  await block();
  for ($i = 0; $i < func_num_args(); ++$i) {
    var_dump(func_get_arg($i));
  }
}

<<__EntryPoint>>
function main_func_get_arg() {
;

HH\Asio\join(num("a", "b", "c"));
HH\Asio\join(arg("e", "f"));
}
