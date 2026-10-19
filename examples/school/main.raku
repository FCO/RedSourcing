#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use School;

sub app(Str :$database, Str :$file, Bool :$demo = False) {
    red-sourcing-defaults(
        :file($file // $?FILE.IO.parent.add('red-sourcing.rakuconf').Str),
        :database($database // %*ENV<REDSOURCING_EXAMPLE_DATABASE> // ($demo ?? ':memory:' !! 'school.db')),
    );
    School::App.new.initialize
}

sub rejected(&work --> Str) {
    my $message = '';
    try { work(); CATCH { default { $message = .message } } }
    die 'Expected a business-rule rejection' unless $message.chars;
    $message
}

multi sub MAIN('demo' = 'demo', Str :$database, Str :$file) {
    my $school = app(:$database, :$file, :demo);
    $school.add-student('alice', 'Alice');
    $school.add-class("class-$_", "Class $_") for 1..11;
    $school.enroll('alice', "class-$_") for 1..10;
    say 'Alice classes: ' ~ $school.student('alice').class-count;
    say 'Eleventh class rejected: ' ~ rejected({ $school.enroll('alice', 'class-11') });
    $school.cancel('alice', 'class-1');
    $school.enroll('alice', 'class-11');
    say 'Alice classes after cancellation and enrollment: ' ~ $school.student('alice').class-count;

    $school.add-class('math', 'Mathematics');
    for 1..31 -> $number {
        $school.add-student("student-$number", "Student $number");
        $school.enroll("student-$number", 'math') if $number <= 30;
    }
    say 'Math students: ' ~ $school.classroom('math').student-count;
    say 'Thirty-first student rejected: ' ~ rejected({ $school.enroll('student-31', 'math') });
    $school.cancel('student-1', 'math');
    $school.enroll('student-31', 'math');
    say 'Math students after cancellation and enrollment: ' ~ $school.classroom('math').student-count;
    say 'Replayed active enrollments: ' ~ SchoolOverview.^with-ids.^load.enrollment-count;
}

multi sub MAIN('student-add', Str $id, Str :$name!, Str :$database, Str :$file) {
    say app(:$database, :$file).add-student($id, $name);
}
multi sub MAIN('class-add', Str $id, Str :$title!, Str :$database, Str :$file) {
    say app(:$database, :$file).add-class($id, $title);
}
multi sub MAIN('enroll', Str $student, Str $class, Str :$database, Str :$file) {
    say app(:$database, :$file).enroll($student, $class) ?? 'Enrolled' !! 'Already enrolled';
}
multi sub MAIN('cancel', Str $student, Str $class, Str :$database, Str :$file) {
    say app(:$database, :$file).cancel($student, $class) ?? 'Cancelled' !! 'Already inactive';
}
multi sub MAIN('student', Str $id, Str :$database, Str :$file) {
    my $view = app(:$database, :$file).student($id);
    die "Unknown student: $id" unless $view.exists;
    say "$id: {$view.name}";
    say "Classes ({$view.class-count}/10): " ~ $view.classes.keys.sort.join(', ');
}
multi sub MAIN('class', Str $id, Str :$database, Str :$file) {
    my $view = app(:$database, :$file).classroom($id);
    die "Unknown class: $id" unless $view.exists;
    say "$id: {$view.title}";
    say "Students ({$view.student-count}/30): " ~ $view.students.keys.sort.join(', ');
}
multi sub MAIN('summary', Str :$database, Str :$file) {
    my $view = app(:$database, :$file).summary;
    say "Students: {$view.students.elems}; classes: {$view.classes.elems}; active enrollments: {$view.enrollment-count}";
}
