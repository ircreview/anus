/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "mplex.h"

int q_bound(struct queue* q, int min, int ideal, int max) {
	if (ideal < min)
		ideal = min;
	if (q->start == q->end) {
		q->start = q->end = 0;
		if (q->size > max) {
			free(q->data);
			q->data = malloc(ideal);
			q->size = ideal;
		}
	}
	int slack = q->size - q->end;
	if (slack < min) {
		int size = q->end - q->start;
		if (slack + q->start > min) {
			memmove(q->data, q->data + q->start, size);
			slack += q->start;
			q->start = 0;
			q->end = size;
		} else {
			int newsiz = (size * 3)/2 + min;
			if (newsiz < ideal)
				newsiz = ideal;
			uint8_t* dat = malloc(newsiz);
			memcpy(dat, q->data + q->start, size);
			free(q->data);
			q->data = dat;
			q->size = newsiz;
			q->start = 0;
			q->end = size;
			slack = newsiz - size;
		}
	}
	return slack;
}

int q_read(int fd, struct queue* q) {
	int slack = q_bound(q, MIN_RECVQ, IDEAL_RECVQ, IDEAL_RECVQ);

	int len = read(fd, q->data + q->end, slack);
	if (len > 0) {
		q->end += len;
		return 0;
	} else if (len == -1 && (errno == EAGAIN || errno == EINTR)) {
		return 0;
	} else {
		return 1;
	}
}

int q_write(int fd, struct queue* q) {
	int size = q->end - q->start;
	if (size) {
		int len = write(fd, q->data + q->start, size);
		if (len > 0) {
			q->start += len;
		} else if (len == -1 && (errno == EAGAIN || errno == EINTR)) {
			return 0;
		} else {
			return 1;
		}
	}
	return 0;
}

char* q_gets(struct queue* q) {
	int i;
	for(i = q->start; i < q->end; i++) {
		if (q->data[i] == '\r' || q->data[i] == '\n') {
			if (i == q->start) {
				q->start++;
			} else {
				uint8_t* rv = q->data + q->start;
				q->data[i] = '\0';
				q->start = i+1;
				return (char*)rv;
			}
		}
	}
	return NULL;
}

void q_puts(struct queue* q, char* line, int wide_newline) {
	int slen = strlen(line);
	int needed = slen + 1 + wide_newline;
	q_bound(q, needed, IDEAL_RECVQ, IDEAL_RECVQ);
	memcpy(q->data + q->end, line, slen);
	q->end += slen;
	if (wide_newline)
		q->data[q->end++] = '\r';
	q->data[q->end++] = '\n';
}

void fdprintf(int fd, const char* format, ...) {
	char fastbuf[8192];
	char* slowbuf = NULL;
	char* at;
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf(fastbuf, 8192, format, ap);
	va_end(ap);
	if (n >= 8192) {
		n++;
		slowbuf = at = malloc(n);
		va_start(ap, format);
		n = vsnprintf(slowbuf, n, format, ap);
		va_end(ap);
	} else if (n >= 0) {
		at = fastbuf;
	} else {
		abort();
	}
	while (n) {
		int r = write(fd, at, n);
		if (r <= 0) {
			exit(1);
		}
		at += r;
		n -= r;
	}
	if (slowbuf)
		free(slowbuf);
}