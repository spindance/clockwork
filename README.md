Clockwork - a clock process to replace cron [![Build Status](https://secure.travis-ci.org/tomykaira/clockwork.png?branch=master)](http://travis-ci.org/tomykaira/clockwork) [![Dependency Status](https://gemnasium.com/tomykaira/clockwork.png)](https://gemnasium.com/tomykaira/clockwork)
===========================================

Cron is non-ideal for running scheduled application tasks, especially in an app
deployed to multiple machines.  [More details.](http://adam.heroku.com/past/2010/4/13/rethinking_cron/)

Clockwork is a cron replacement.  It runs as a lightweight, long-running Ruby
process which sits alongside your web processes (Mongrel/Thin) and your worker
processes (DJ/Resque/Minion/Stalker) to schedule recurring work at particular
times or dates.  For example, refreshing feeds on an hourly basis, or send
reminder emails on a nightly basis, or generating invoices once a month on the
1st.

Quickstart
----------

Create clock.rb:

```ruby
require 'clockwork'
module Clockwork
  handler do |job|
    puts "Running #{job}"
  end

  # handler receives the time when job is prepared to run in the 2nd argument
  # handler do |job, time|
  #   puts "Running #{job}, at #{time}"
  # end

  every(10.seconds, 'frequent.job')
  every(3.minutes, 'less.frequent.job')
  every(1.hour, 'hourly.job')

  every(1.day, 'midnight.job', :at => '00:00')
end
```

Run it with the clockwork binary:

```
$ clockwork clock.rb
Starting clock for 4 events: [ frequent.job less.frequent.job hourly.job midnight.job ]
Triggering frequent.job
```

If you need to load your entire environment for your jobs, simply add:

```ruby
require './config/boot'
require './config/environment'
```

under the `require 'clockwork'` declaration.

Quickstart for Heroku
---------------------

Clockwork fits well with heroku's cedar stack.

Consider to use [clockwork-init.sh](https://gist.github.com/1312172) to create
a new project for heroku.

Use with queueing
-----------------

The clock process only makes sense as a place to schedule work to be done, not
to do the work.  It avoids locking by running as a single process, but this
makes it impossible to parallelize.  For doing the work, you should be using a
job queueing system, such as
[Delayed Job](http://www.therailsway.com/2009/7/22/do-it-later-with-delayed-job),
[Beanstalk/Stalker](http://adam.heroku.com/past/2010/4/24/beanstalk_a_simple_and_fast_queueing_backend/),
[RabbitMQ/Minion](http://adam.heroku.com/past/2009/9/28/background_jobs_with_rabbitmq_and_minion/),
[Resque](http://github.com/blog/542-introducing-resque), or
[Sidekiq](https://github.com/mperham/sidekiq).  This design allows a
simple clock process with no locks, but also offers near infinite horizontal
scalability.

For example, if you're using Beanstalk/Stalker:

```ruby
require 'stalker'

module Clockwork
  handler { |job| Stalker.enqueue(job) }

  every(1.hour, 'feeds.refresh')
  every(1.day, 'reminders.send', :at => '01:30')
end
```

Using a queueing system which doesn't require that your full application be
loaded is preferable, because the clock process can keep a tiny memory
footprint.  If you're using DJ or Resque, however, you can go ahead and load
your full application enviroment, and use per-event blocks to call DJ or Resque
enqueue methods.  For example, with DJ/Rails:

```ruby
require 'config/boot'
require 'config/environment'

every(1.hour, 'feeds.refresh') { Feed.send_later(:refresh) }
every(1.day, 'reminders.send', :at => '01:30') { Reminder.send_later(:send_reminders) }
```

Use with database tasks
-----------------------

You can dynamically add tasks from a database to be scheduled along with the regular events in clock.rb.

To do this, use the `sync_database_tasks` method call:

```ruby
require 'clockwork'
require 'clockwork/manager_with_database_tasks'
require_relative './config/boot'
require_relative './config/environment'

module Clockwork

  # required to enable database syncing support
  Clockwork.manager = ManagerWithDatabaseTasks.new

  sync_database_tasks model: MyScheduledTask, every: 1.minute do |instance_job_name|
    # Where your model will acts as a worker:
    id = instance_job_name.split(':').last
    task = MyScheduledTask.find(id)
    task.perform_async

    # Or, e.g. if your queue system just needs job names
    # Stalker.enqueue(instance_job_name)
  end

  [...other tasks if you have...]

end
```

This tells clockwork to fetch all MyScheduledTask instances from the database, and create an event for each, configured based on the instances' `frequency`, `name`, and `at` methods. It also says to reload the tasks from the database every 1.minute - we need to frequently do this as they could have changed (but you can choose a sensible reload frequency by changing the `every:` option).

Rails ActiveRecord models are a perfect candidate for the model class, but you could use something else. The only requirements are:

  1. the class responds to `all` returning an array of instances from the database
  2. the instances returned respond to:
      `frequency` returning the how frequently (in seconds) the database task should be run
      `name` returning the task's job name (this is what gets passed into the block above)
      `at` return nil or `''` if not using `:at`, or otherwise any acceptable clockwork `:at` string

Here's an example of one way of setting up your ActiveRecord models, using Sidekiq for background tasks, and making the model class a worker:

```ruby
# db/migrate/20140302220659_create_frequency_periods.rb
class CreateFrequencyPeriods < ActiveRecord::Migration
  def change
    create_table :frequency_periods do |t|
      t.string :name

      t.timestamps
    end
  end
end

# 20140302221102_create_my_scheduled_tasks.rb
class CreateMyScheduledTasks < ActiveRecord::Migration
  def change
    create_table :my_scheduled_tasks do |t|
      t.integer :frequency_quantity
      t.references :frequency_period
      t.string :at

      t.timestamps
    end
    add_index :my_scheduled_tasks, :frequency_period_id
  end
end

# app/models/my_scheduled_task.rb
class MyScheduledTask < ActiveRecord::Base
  include Sidekiq::Worker

  belongs_to :frequency_period
  attr_accessible :frequency_quantity, :frequency_period_id, :at

  # Used by clockwork to schedule how frequently this task should be run
  # Should be the intended number of seconds between executions
  def frequency
    frequency_quantity.send(frequency_period.name.pluralize)
  end

  # Used by clockwork to name this task internally for its logging
  # Should return a reference for this task to be used in clockwork
  # Include the instance ID if you want to be able to retrieve the
  # model instance inside the sync_database_tasks block in clock.rb
  def name
    "Database_MyScheduledTask:#{id}"
  end

  # Method required by Sidekiq
  def perform
    # the task that will be performed in the background
  end
end

# app/models/frequency_period.rb
class FrequencyPeriod < ActiveRecord::Base
  attr_accessible :name
end

# db/seeds.rb
...
# creating the FrequencyPeriods
[:second, :minute, :hour, :day, :week, :month].each do |period|
  FrequencyPeriod.create(name: period)
end
...
```

You could, of course, create a separate Sidekiq or DelayedJob worker class under app/workers, and simply use the model referenced by clockwork to trigger that worker to run asynchronously.

Event Parameters
----------

### :at

`:at` parameter specifies when to trigger the event:

#### Valid formats:

    HH:MM
     H:MM
    **:MM
    HH:**
    (Mon|mon|Monday|monday) HH:MM

#### Examples

The simplest example:

```ruby
every(1.day, 'reminders.send', :at => '01:30')
```

You can omit the leading 0 of the hour:

```ruby
every(1.day, 'reminders.send', :at => '1:30')
```

Wildcards for hour and minute are supported:

```ruby
every(1.hour, 'reminders.send', :at => '**:30')
every(10.seconds, 'frequent.job', :at => '9:**')
```

You can set more than one timing:

```ruby
every(1.day, 'reminders.send', :at => ['12:00', '18:00'])
# send reminders at noon and evening
```

You can specify the day of week to run:

```ruby
every(1.week, 'myjob', :at => 'Monday 16:20')
```

### :tz

`:tz` parameter lets you specify a timezone (default is the local timezone):

```ruby
every(1.day, 'reminders.send', :at => '00:00', :tz => 'UTC')
# Runs the job each day at midnight, UTC.
# The value for :tz can be anything supported by [TZInfo](http://tzinfo.rubyforge.org/)
```

### :if

`:if` parameter is invoked every time the task is ready to run, and run if the
return value is true.

Run on every first day of month.

```ruby
Clockwork.every(1.day, 'myjob', :if => lambda { |t| t.day == 1 })
```

The argument is an instance of `ActiveSupport::TimeWithZone` if the `:tz` option is set. Otherwise, it's an instance of `Time`.

This argument cannot be omitted.  Please use _ as placeholder if not needed.

```ruby
Clockwork.every(1.second, 'myjob', :if => lambda { |_| true })
```

### :thread

In default, clockwork runs in single-process, single-thread.
If an event handler takes long time, the main routine of clockwork is blocked until it ends.
Clockwork does not misbehave, but the next event is blocked, and runs when the process is returned to the clockwork routine.

This `:thread` option is to avoid blocking. An event with `:thread => true`  runs in a different thread.

```ruby
Clockwork.every(1.day, 'run.me.in.new.thread', :thread => true)
```

If a job is long-running or IO-intensive, this option helps keep the clock precise.

Custom Job Options
-----------------------

You can specify a hash of custom job options which are passed to the handler.

### Example:

```ruby
handler do |job, time, options|
  puts "Running #{job} with custom options #{options}"
end

every(1.day, 'reminders.send', { :at => '01:30' }, { :via_sms => false })
```

Configuration
-----------------------

Clockwork exposes a couple of configuration options:

### :logger

By default Clockwork logs to `STDOUT`. In case you prefer your
own logger implementation you have to specify the `logger` configuration option. See example below.

### :sleep_timeout

Clockwork wakes up once a second and performs its duties. To change the number of seconds Clockwork
sleeps, set the `sleep_timeout` configuration option as shown below in the example.

### :tz

This is the default timezone to use for all events.  When not specified this defaults to the local
timezone.  Specifying :tz in the parameters for an event overrides anything set here.

### :max_threads

Clockwork runs handlers in threads. If it exceeds `max_threads`, it will warn you (log an error) about missing
jobs.


### :thread

Boolean true or false. Default is false. If set to true, every event will be run in its own thread. Can be overridden on a per event basis (see the ```:thread``` option in the Event Parameters section above)

### Configuration example

```ruby
module Clockwork
  configure do |config|
    config[:sleep_timeout] = 5
    config[:logger] = Logger.new(log_file_path)
    config[:tz] = 'EST'
    config[:max_threads] = 15
    config[:thread] = true
  end
end
```

### error_handler

You can add error_handler to define your own logging or error rescue.

```ruby
module Clockwork
  error_handler do |error|
    Airbrake.notify_or_ignore(error)
  end
end
```

Current specifications are as follows.

- defining error_handler does not disable original logging
- errors from error_handler itself are not rescued, and stop clockwork

Any suggestion about these specifications is welcome.

Old style
---------

`include Clockwork` is old style.
The old style is still supported, though not recommended, because it pollutes the global namespace.



Anatomy of a clock file
-----------------------

clock.rb is standard Ruby.  Since we include the Clockwork module (the
clockwork binary does this automatically, or you can do it explicitly), this
exposes a small DSL to define the handler for events, and then the events themselves.

The handler typically looks like this:

```ruby
handler { |job| enqueue_your_job(job) }
```

This block will be invoked every time an event is triggered, with the job name
passed in.  In most cases, you should be able to pass the job name directly
through to your queueing system.

The second part of the file, which lists the events, roughly resembles a crontab:

```ruby
every(5.minutes, 'thing.do')
every(1.hour, 'otherthing.do')
```

In the first line of this example, an event will be triggered once every five
minutes, passing the job name 'thing.do' into the handler.  The handler shown
above would thus call enqueue_your_job('thing.do').

You can also pass a custom block to the handler, for job queueing systems that
rely on classes rather than job names (i.e. DJ and Resque).  In this case, you
need not define a general event handler, and instead provide one with each
event:

```ruby
every(5.minutes, 'thing.do') { Thing.send_later(:do) }
```

If you provide a custom handler for the block, the job name is used only for
logging.

You can also use blocks to do more complex checks:

```ruby
every(1.day, 'check.leap.year') do
  Stalker.enqueue('leap.year.party') if Date.leap?(Time.now.year)
end
```

In addition, Clockwork also supports `:before_tick` and `after_tick` callbacks.
They are optional, and run every tick (a tick being whatever your `:sleep_timeout`
is set to, default is 1 second):

```ruby
on(:before_tick) do
  puts "tick"
end

on(:after_tick) do
  puts "tock"
end
```

Finally, you can use tasks synchronised from a database as described in detail above:

```ruby
sync_database_tasks model: MyScheduledTask, every: 1.minute do |instance_job_name|
  # what to do with each instance
end
```

You can use multiple `sync_database_tasks` if you wish, so long as you use different model classes for each (ActiveRecord Single Table Inheritance could be a good idea if you're doing this).

In production
-------------

Only one clock process should ever be running across your whole application
deployment.  For example, if your app is running on three VPS machines (two app
servers and one database), your app machines might have the following process
topography:

* App server 1: 3 web (thin start), 3 workers (rake jobs:work), 1 clock (clockwork clock.rb)
* App server 2: 3 web (thin start), 3 workers (rake jobs:work)

You should use Monit, God, Upstart, or Inittab to keep your clock process
running the same way you keep your web and workers running.

Daemonization
-------------

Thanks to @fddayan, `clockworkd` executes clockwork script as a daemon.

You will need the `daemons` gem to use `clockworkd`.  It is not automatically installed, please install by yourself.

Then,

```
clockworkd -c YOUR_CLOCK.rb start
```

For more details, see help shown by `clockworkd`.

Issues and Pull requests
------------------------

If you find a bug, please create an issue - [Issues · tomykaira/clockwork](https://github.com/tomykaira/clockwork/issues).

For a bug fix or a feature request, please send a pull-request.
Do not forget to add tests to show how your feature works, or what bug is fixed.
All existing tests and new tests must pass (TravisCI is watching).

We want to provide simple and customizable core, so superficial changes will not be merged (e.g. supporting new event registration style).
In most cases, directly operating `Manager` realizes an idea, without touching the core.
If you discover a new way to use Clockwork, please create a gist page or an article on your website, then add it to the following "Use cases" section.
This tool is already used in various environment, so backward-incompatible requests will be mostly rejected.

Use cases
---------

Feel free to add your idea or experience and send a pull-request.

- [Sending errors to Airbrake](https://github.com/tomykaira/clockwork/issues/58)
- [Read events from a database](https://github.com/tomykaira/clockwork/issues/25)

Meta
----

Created by Adam Wiggins

Inspired by [rufus-scheduler](https://github.com/jmettraux/rufus-scheduler) and [resque-scheduler](https://github.com/bvandenbos/resque-scheduler)

Design assistance from Peter van Hardenberg and Matthew Soldo

Patches contributed by Mark McGranaghan and Lukáš Konarovský

Released under the MIT License: http://www.opensource.org/licenses/mit-license.php

http://github.com/tomykaira/clockwork
