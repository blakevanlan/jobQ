# jobQ

jobQ is a parallelizable job queue with locking functionality; built with node.js + redis.
This code is a genericized version of a project originally developed for the [Fannect](http://www.fannect.me) platform. That repo had sensitive information in previous check ins so a separated repo had to be created for this one (hence the single massive original commit).

At the time of creation, [Kue](https://github.com/LearnBoost/kue/), a far more feature rich job queue, did not support anyway to ensure that certain jobs of the same type did not run in parallel. If this isn't a use case for you then I highly recommend using Kue instead.

Installation

```javascript
npm install job-q
```

# Queueing

Before queuing, a job `queue` must be initialized; either by newing up an instance of `jobQ.Queue` and passing in an already created redis client or by using the conviency method of `jobQ.createQueueWithUrl` which accepts a redis URL and a callback function. 

```javascript
var jobQ = require('job-q');
var Queue = jobQ.Queue;

var queue = new Queue(client);
```
or
```javascript
var jobQ = require('job-q');

jobQ.createQueueWithUrl('redis://...', function (err, queue) {
   // ...
});
```

After a queue has been created adding a job is as straightforward as calling `queue.createJob(id, data, cb)` or `queue.createLockingJob(id, lock, data, cb)`.
```javascript
queue.createJob('reset', {
   email: 'blakevanlan@gmail.com'
}, function (err) {
   // ...
});

queue.createLockingJob('reset', 'reset-blakevanlan@gmail.com', {
   email: 'blakevanlan@gmail.com'
}, function (err) {
   // ...
});
```
The above example is meant to highlight the flexibility of the lock. Many times it is useful to embed information in the lock to keep it from being overly broad (and blocking too many jobs without reason).

# Processing

A jobQ Worker only processes a single job at a time; however, there is no reason why an app can't spin up multiple Workers within a process.

Processing jobs is simple to set up. Similar to the queue, it begins with initializing an instance of the Worker object. The same conviency method exists for creating a Worker with a redis URL.

```javascript
var jobQ = require('job-q');
var Worker = jobQ.Worker;

var worker = new Worker(client);
```
or
```javascript
var jobQ = require('job-q');

jobQ.createWorkerWithUrl('redis://...', function (err, worker) {
   // ...
});
```

For a job to be processed, it must have a handler specificed so the worker knows what to do.

```javascript
worker.addHandler('reset', function (job, done) {
   // ...
});
```

And finally, the Worker needs to be started.
```javascript
worker.start();
```

Also, a Worker can be stopped. `worker.stop` accepts an optional callback.
```javascript
worker.stop();
```

## Events

The Worker object inherits from the EventEmitter. Here are the events it emits:

### start
Emitted every time the Worker starts.
```javascript
worker.on('start', function () {
   // ... 
});
```

### active
Emitted every time the Worker goes from waiting to processing.
```javascript
worker.on('active', function () {
   // ... 
});
```

### waiting
Emitted every time the Worker finishes the last job and starts waiting.
```javascript
worker.on('waiting', function () {
   // ... 
});
```

### stop
Emitted every time the Worker is stopped.
```javascript
worker.on('stop', function () {
   // ... 
});
```

### process
Emitted before the Worker begins to process a job.
```javascript
worker.on('process', function (job) {
   // ... 
});
```

### complete
Emitted after the Worker finishes processing a job.
```javascript
worker.on('complete', function (job) {
   // ... 
});
```

### job_error
Emitted when the Worker hits an error when processing a job. This can be because the job is invalid or because of an error within the job itself.
```javascript
worker.on('job_error', function (err, job) {
   // ... 
});
```

### error
Emitted every time the Worker hits an error, usually a connection error.
```javascript
worker.on('error', function (desc, err) {
   // ... 
});
```
