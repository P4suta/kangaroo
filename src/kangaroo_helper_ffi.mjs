export function metadata(_value) {}

export function serial() {}

export function skip(reason) {
  const error = new Error(`kangaroo skip: ${reason}`);
  error.kangaroo_skip = true;
  error.reason = reason;
  throw error;
}

const isPromise = (value) => value && typeof value.then === "function";

export function fixture(setup, teardown, body) {
  const resource = setup();
  if (isPromise(resource)) {
    return resource.then((resolved) => fixtureValue(resolved, teardown, body));
  }
  return fixtureValue(resource, teardown, body);
}

function fixtureValue(resource, teardown, body) {
  let bodyValue;
  try {
    bodyValue = body(resource);
  } catch (bodyError) {
    return finishFailure(resource, teardown, bodyError);
  }

  if (isPromise(bodyValue)) {
    return bodyValue.then(
      async (value) => {
        await teardown(resource);
        return value;
      },
      (bodyError) => finishFailureAsync(resource, teardown, bodyError),
    );
  }

  const cleanup = teardown(resource);
  if (isPromise(cleanup)) return cleanup.then(() => bodyValue);
  return bodyValue;
}

function finishFailure(resource, teardown, bodyError) {
  try {
    const cleanup = teardown(resource);
    if (isPromise(cleanup)) {
      return cleanup.then(
        () => Promise.reject(bodyError),
        (cleanupError) => Promise.reject(combined(bodyError, cleanupError)),
      );
    }
  } catch (cleanupError) {
    throw combined(bodyError, cleanupError);
  }
  throw bodyError;
}

async function finishFailureAsync(resource, teardown, bodyError) {
  try {
    await teardown(resource);
  } catch (cleanupError) {
    throw combined(bodyError, cleanupError);
  }
  throw bodyError;
}

function combined(bodyError, cleanupError) {
  return new AggregateError(
    [bodyError, cleanupError],
    `fixture body failed: ${message(bodyError)}; teardown failed: ${message(cleanupError)}`,
  );
}

function message(error) {
  return error && error.message ? error.message : String(error);
}
