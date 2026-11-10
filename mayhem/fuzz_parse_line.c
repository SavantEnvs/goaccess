/* libFuzzer harness: parse one access-log line with goaccess's own log parser (dry run).
 * Input byte 0 picks the log format (a preset, or -- for the last index -- a custom format
 * taken from the text up to the first '\n'); the remaining bytes are the log line. */
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include "browsers.h"
#include "commons.h"
#include "parser.h"
#include "settings.h"

static const char *const PRESETS[] = {
  "COMBINED", "VCOMBINED", "VCOMBINED_PORT", "COMMON", "VCOMMON", "VCOMMON_PORT", "W3C",
  "CLOUDFRONT", "CLOUDSTORAGE", "AWSELB", "SQUID", "AWSS3", "AWSALB", "TRAEFIKCLF",
};
#define NPRESETS (sizeof (PRESETS) / sizeof (PRESETS[0]))

int
LLVMFuzzerInitialize (int *argc, char ***argv) {
  (void) argc;
  (void) argv;
  parse_browsers_file ();
  return 0;
}

int
LLVMFuzzerTestOneInput (const uint8_t *data, size_t size) {
  GLog glog;
  GLogItem *item = NULL;
  const char *body;
  size_t body_len;
  char *line, *custom = NULL;
  unsigned sel;

  if (size < 2)
    return -1;

  conf.is_json_log_format = 0;
  sel = data[0] % (NPRESETS + 1);
  body = (const char *) data + 1;
  body_len = size - 1;

  if (sel == NPRESETS) {
    const char *nl = memchr (body, '\n', body_len);
    if (!nl)
      return -1;
    custom = malloc ((size_t) (nl - body) + 1);
    memcpy (custom, body, (size_t) (nl - body));
    custom[nl - body] = '\0';
    if (*custom == '\0') {
      free (custom);
      return -1;
    }
    body_len -= (size_t) (nl - body) + 1;
    body = nl + 1;
    set_log_format_str (custom);
    /* A JSON log format is registered in goaccess's hash storage by set_spec_date_format(),
     * which this harness does not initialize (and which exits on a bad JSON format). */
    if (conf.is_json_log_format) {
      free (custom);
      return -1;
    }
    set_date_format_str ("%d/%b/%Y");
    set_time_format_str ("%H:%M:%S");
  } else {
    set_log_format_str (PRESETS[sel]);
  }
  set_spec_date_format ();

  line = malloc (body_len + 1);
  memcpy (line, body, body_len);
  line[body_len] = '\0';

  memset (&glog, 0, sizeof glog);
  glog.errors = calloc (MAX_LOG_ERRORS, sizeof (char *));
  pthread_mutex_init (&glog.error_mutex, NULL);

  parse_line (&glog, line, 1, &item);
  free_logerrors (&glog);

  pthread_mutex_destroy (&glog.error_mutex);
  free (glog.errors);
  free (line);
  free (custom);
  return 0;
}
