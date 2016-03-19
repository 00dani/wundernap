moment = require 'moment'
Promise = require 'bluebird'
R = require 'ramda'

now = moment()
today = now.format 'YYYY-MM-DD'
auth = require './auth.json'
api = (require 'request-promise').defaults {
  baseUrl: 'https://a.wunderlist.com/api/v1/'
  json: true
  headers:
    'X-Access-Token': auth.accessToken
    'X-Client-ID': auth.clientId
}

fetchTasks = (allLists) ->
  Promise.all allLists.map (list) ->
    api.get url: 'tasks', qs: list_id: list.id
      .then fetchReminders
      .then (tasks) ->
        list.tasks = tasks
        return list

fetchReminders = (allTasks) ->
  Promise.all allTasks.map (task) ->
    api.get url: '/reminders', qs: task_id: task.id
      .then (reminders) ->
        task.reminder = reminders[0]
        return task

lists = api.get 'lists'
  .then fetchTasks
  .then R.indexBy R.prop 'title'

isRecurring = R.where recurrence_type: R.identity
isSnoozeTagged = R.where title: R.test /#snooze\b/
isSnoozable = R.allPass [
  R.anyPass [isRecurring, isSnoozeTagged]
  R.where {
    due_date: R.complement R.equals today
    reminder: R.identity
  }
]
isDue = (task) -> not task.reminder or (moment task.reminder.date).isSameOrBefore now

moveTask = (task, dest) ->
  snoozedKeys = [
    'list_id'
    'assignee_id', 'due_date', 'starred'
    'recurrence_count', 'recurrence_type'
  ]
  changes = list_id: dest.id, revision: task.revision
  if m = /^(.*) #snoozed (.*)$/.exec task.title
    changes.title = m[1]
    changes = R.merge changes, JSON.parse m[2]
  else
    changes.title = task.title + ' #snoozed ' + JSON.stringify (R.pick snoozedKeys, task)
    changes.remove = R.tail snoozedKeys

  action = if changes.remove then 'Snoozing' else 'Awakening'
  console.log "#{action} task '#{task.title}' to list '#{dest.title}'"
  api.patch url: "/tasks/#{task.id}", body: changes

snooze = Promise.coroutine (list) ->
  tasks = list.tasks.filter isSnoozable
  console.log "Found #{tasks.length} tasks to snooze in list '#{list.title}'."
  return if tasks.length is 0
  dest = (yield lists).Snoozed
  for task in tasks
    moveTask task, dest

awaken = Promise.coroutine (list) ->
  tasks = list.tasks.filter isDue
  console.log "Found #{tasks.length} tasks to awaken."
  return if tasks.length is 0
  dest = (yield lists).inbox
  for task in tasks
    moveTask task, dest, today

lists.then (allLists) ->
  results = for listName, list of allLists
    if listName is 'Snoozed'
      awaken list
    else
      snooze list
  Promise.all results
